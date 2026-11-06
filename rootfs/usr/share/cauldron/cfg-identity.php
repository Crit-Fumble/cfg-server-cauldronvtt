<?php
	/* The platform's sign-in, through Banshee's own client-certificate login.
	 *
	 * Banshee signs a user in when $_SERVER["HTTPS"] is "on" and $_SERVER["TLS_CERT_SERIAL"]
	 * matches users.cert_serial (models/banshee/login.php, user::login_ssl_auth). No client
	 * certificate reaches this container. The platform's edge vouches for the member instead,
	 * with one header on each request it forwards:
	 *
	 *   X-Cfg-Kind-Identity: v1.<serial>.<expires>.<mac>
	 *
	 * <mac> is the hex HMAC-SHA256 of "v1.<serial>.<expires>" under this server's edge key,
	 * which the platform hands the container at launch (CAULDRON_EDGE_KEY; the entrypoint
	 * writes it to /tmp/cauldron/edge.key, readable by this uid alone). <expires> is a Unix time at
	 * most five minutes ahead. A header that verifies stands in for the certificate, so
	 * Banshee's login runs as it would for one: only for a visitor not signed in yet, on a
	 * private page, and the session it makes is Banshee's own. Any other header is dropped
	 * here, so without the key nobody can sign anyone in, whatever they send.
	 *
	 * HTTPS is set because Banshee accepts a certificate only over TLS, which the edge
	 * terminates; behind the platform, nginx already sets it from X-Forwarded-Proto.
	 *
	 * php-fpm prepends this file to index.php, the one script nginx runs
	 * (php_admin_value[auto_prepend_file] in www.conf).
	 */

	(function () {
		$header = $_SERVER["HTTP_X_CFG_KIND_IDENTITY"] ?? null;
		unset($_SERVER["HTTP_X_CFG_KIND_IDENTITY"], $_SERVER["TLS_CERT_SERIAL"]);

		if (is_string($header) == false) {
			return;
		}
		$parts = explode(".", $header);
		if ((count($parts) != 4) || ($parts[0] !== "v1")) {
			return;
		}
		list(, $serial, $expires, $mac) = $parts;
		if ((preg_match('/^[1-9][0-9]{0,9}$/', $serial) !== 1) || ((int)$serial > 4294967295)) {
			return;
		}
		if ((preg_match('/^[0-9]{1,12}$/', $expires) !== 1) || (preg_match('/^[0-9a-f]{64}$/', $mac) !== 1)) {
			return;
		}
		$now = time();
		if (((int)$expires < $now) || ((int)$expires > $now + 300)) {
			return;
		}

		$key = @file_get_contents("/tmp/cauldron/edge.key");
		if (($key === false) || (strlen($key) < 32)) {
			return;
		}
		if (hash_equals(hash_hmac("sha256", "v1.".$serial.".".$expires, $key), $mac) == false) {
			return;
		}

		$_SERVER["TLS_CERT_SERIAL"] = $serial;
		$_SERVER["HTTPS"] = "on";
	})();
