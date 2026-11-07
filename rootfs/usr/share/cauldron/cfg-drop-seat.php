<?php
	/* The platform ends a member's table sockets at once (cs#767): when the host takes their seat
	 * back, or the member is banned or suspended. Without it the edge refuses the member's next
	 * request, but a table already open stays open.
	 *
	 * nginx tags each table socket with the seat the edge signed its upgrade for, and cauldrond
	 * keeps it (patches/cauldrond-seat-drop.patch). core-server calls this route on the container
	 * network, never through the edge, with one header:
	 *
	 *   X-Cfg-Kind-Command: v1.drop.<serial>.<expires>.<mac>
	 *
	 * <mac> is the hex HMAC-SHA256 of "v1.drop.<serial>.<expires>" under the edge key the identity
	 * header is signed with (cfg-identity.php); "drop" keeps one from passing for the other.
	 * <expires> is a Unix time at most a minute ahead, so a command seen once is not good for long.
	 *
	 * POST only. 200 {"dropped": <n>}, how many sockets ended (0 when the member had none open);
	 * 403 for a header that does not verify; 503 when cauldrond does not answer.
	 */

	function answer($status, $body) {
		http_response_code($status);
		header("Content-Type: application/json");
		header("Cache-Control: no-store");
		print json_encode($body);
		exit;
	}

	if (($_SERVER["REQUEST_METHOD"] ?? "") !== "POST") {
		header("Allow: POST");
		answer(405, array("error" => "POST only"));
	}

	$parts = explode(".", $_SERVER["HTTP_X_CFG_KIND_COMMAND"] ?? "");
	if ((count($parts) != 5) || ($parts[0] !== "v1") || ($parts[1] !== "drop")) {
		answer(403, array("error" => "Forbidden"));
	}
	list(, , $serial, $expires, $mac) = $parts;
	if ((preg_match('/^[1-9][0-9]{0,9}$/', $serial) !== 1) || ((int)$serial > 4294967295)) {
		answer(403, array("error" => "Forbidden"));
	}
	if ((preg_match('/^[0-9]{1,12}$/', $expires) !== 1) || (preg_match('/^[0-9a-f]{64}$/', $mac) !== 1)) {
		answer(403, array("error" => "Forbidden"));
	}
	$now = time();
	if (((int)$expires < $now) || ((int)$expires > $now + 60)) {
		answer(403, array("error" => "Forbidden"));
	}

	$key = @file_get_contents("/tmp/cauldron/edge.key");
	if (($key === false) || (strlen($key) < 32)) {
		answer(403, array("error" => "Forbidden"));
	}
	if (hash_equals(hash_hmac("sha256", "v1.drop.".$serial.".".$expires, $key), $mac) == false) {
		answer(403, array("error" => "Forbidden"));
	}

	$daemon = @stream_socket_client("unix:///tmp/cauldron/cauldrond.sock", $errno, $errstr, 2);
	if ($daemon === false) {
		answer(503, array("error" => "cauldrond is not answering"));
	}
	stream_set_timeout($daemon, 2);
	fwrite($daemon, "drop ".$serial."\n");
	$line = fgets($daemon);
	fclose($daemon);
	if (($line === false) || (preg_match('/^([0-9]+)\n$/', $line, $match) !== 1)) {
		answer(503, array("error" => "cauldrond did not take the command"));
	}

	error_log("[cfg-server-cauldronvtt] seat ".$serial.": ".$match[1]." table socket(s) ended");
	answer(200, array("dropped" => (int)$match[1]));
