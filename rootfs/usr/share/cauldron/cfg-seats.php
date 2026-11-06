<?php
	/* The platform's seats on this server, written before the app starts (entrypoint.sh,
	 * sync_seats). The entrypoint runs it when the platform passes CAULDRON_SEATS or
	 * CAULDRON_ADMIN_CERT_SERIAL; with no CAULDRON_SEATS at all (an empty one is a list with
	 * no seats), no account but the admin's is touched.
	 *
	 * CAULDRON_SEATS has one line per member who holds a seat:
	 *
	 *   <serial> <username> <full name>
	 *
	 * The serial is the cert_serial Banshee's certificate login matches (cfg-identity.php).
	 * Accounts are matched by it, so a member keeps their account, and their characters,
	 * across a revoke and a re-grant. For each seat:
	 *
	 *   - with no account, one is made: a Player in the admin's group, active, with no
	 *     password that verifies (the member signs in through the platform, never with one).
	 *     Its username is the line's, or the first free one of <username>-2 to -9;
	 *   - a deactivated account is active again.
	 *
	 * The seat list decides who is active: an account that carries a serial and is no longer
	 * a seat is deactivated, never deleted, so its characters and adventures stay. The admin
	 * gets CAULDRON_ADMIN_CERT_SERIAL, the host's. Nothing else is written: names, roles and
	 * characters are the host's to change, in Cauldron.
	 *
	 * A malformed list stops the boot (exit 1): it is a platform bug, and a quiet partial
	 * sync would lock members out without a word.
	 */

	require "/var/www/cauldron/libraries/banshee/core/banshee.php";
	require "/var/www/cauldron/libraries/cauldron.php";

	const MAX_SERIAL = 4294967295;
	const SERIAL_RE = '/^[1-9][0-9]{0,9}$/';
	const SEAT_RE = '/^([1-9][0-9]{0,9}) ([a-z0-9][a-z0-9-]{2,29}) (\S.*)$/u';
	// Upstream's seed hashes nothing ('none'); '!' is no hash either, so no password verifies.
	const NO_PASSWORD = "!";

	function say($message) {
		print "[cfg-server-cauldronvtt] ".$message."\n";
	}

	function fail($message) {
		fwrite(STDERR, "[cfg-server-cauldronvtt] FATAL: ".$message."\n");
		exit(1);
	}

	function is_serial($value) {
		return (preg_match(SERIAL_RE, $value) === 1) && ((int)$value <= MAX_SERIAL);
	}

	function parse_seats($raw) {
		$seats = array();
		$usernames = array();
		foreach (preg_split('/\r?\n/', $raw) as $index => $line) {
			if (trim($line) === "") {
				continue;
			}
			$number = $index + 1;
			if ((preg_match(SEAT_RE, $line, $match) !== 1) || ((int)$match[1] > MAX_SERIAL)) {
				fail("CAULDRON_SEATS line ".$number." is not '<serial> <username> <full name>'");
			}
			list(, $serial, $username, $fullname) = $match;
			$fullname = trim(preg_replace('/\p{C}+/u', "", $fullname));
			if (($fullname === "") || (mb_strlen($fullname) > 50)) {
				fail("CAULDRON_SEATS line ".$number.": the full name must be 1 to 50 characters");
			}
			if (isset($seats[$serial]) || isset($usernames[$username])) {
				fail("CAULDRON_SEATS line ".$number." repeats a serial or a username");
			}
			$seats[$serial] = array("serial" => (int)$serial, "username" => $username, "fullname" => $fullname);
			$usernames[$username] = true;
		}

		return $seats;
	}

	/* The line's username, or the first free one of <username>-2 to -9.
	 */
	function free_username($db, $username) {
		for ($n = 1; $n <= 9; $n++) {
			$candidate = ($n == 1) ? $username : $username."-".$n;
			$taken = $db->execute_query("select 1 from users where username = ? or email = ?", array($candidate, $candidate."@seat.invalid"));
			if ($taken->num_rows == 0) {
				return $candidate;
			}
		}

		return null;
	}

	$admin_username = getenv("CAULDRON_ADMIN_USERNAME") ?: "admin";
	$admin_serial = getenv("CAULDRON_ADMIN_CERT_SERIAL") ?: null;
	if (($admin_serial !== null) && (is_serial($admin_serial) == false)) {
		fail("CAULDRON_ADMIN_CERT_SERIAL is not a number from 1 to ".MAX_SERIAL);
	}
	$seat_list = getenv("CAULDRON_SEATS");
	$seats = ($seat_list === false) ? array() : parse_seats($seat_list);

	mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
	try {
		$db = new mysqli("localhost", "root", "", getenv("CAULDRON_DB_NAME") ?: "cauldron", 0, "/tmp/cauldron/mysqld/mysqld.sock");
		$db->set_charset("utf8mb4");
		$db->begin_transaction();

		$admin = $db->execute_query("select id, organisation_id from users where username = ?", array($admin_username))->fetch_assoc();
		if ($admin == null) {
			fail("there is no '".$admin_username."' account to give the host's serial");
		}

		/* The host's serial, on the admin alone: Banshee signs in the first account it finds
		 * with a serial, so no other may share it.
		 */
		if ($admin_serial !== null) {
			$db->execute_query("update users set cert_serial = null where cert_serial = ? and id != ?", array($admin_serial, $admin["id"]));
			if ($db->affected_rows > 0) {
				say("took the host's serial from another account");
			}
			$db->execute_query("update users set cert_serial = ? where id = ?", array($admin_serial, $admin["id"]));
		}

		if ($seat_list === false) {
			$db->commit();
			exit(0);
		}

		$created = $reactivated = 0;
		foreach ($seats as $seat) {
			if (($admin_serial !== null) && ($seat["serial"] == $admin_serial)) {
				say("seat ".$seat["username"]." skipped: its serial is the host's");
				unset($seats[$seat["serial"]]);
				continue;
			}

			$account = $db->execute_query("select id, status from users where cert_serial = ?", array($seat["serial"]))->fetch_assoc();
			if ($account != null) {
				if ((int)$account["status"] == USER_STATUS_DISABLED) {
					$db->execute_query("update users set status = ? where id = ?", array(USER_STATUS_ACTIVE, $account["id"]));
					$reactivated++;
				}
				continue;
			}

			if (($username = free_username($db, $seat["username"])) === null) {
				fail("no free username for seat ".$seat["username"]);
			}
			$db->execute_query(
				"insert into users (organisation_id, username, password, one_time_key, cert_serial, status, authenticator_secret, fullname, email, keyboard) ".
				"values (?, ?, ?, null, ?, ?, null, ?, ?, 0)",
				array($admin["organisation_id"], $username, NO_PASSWORD, $seat["serial"], USER_STATUS_ACTIVE, $seat["fullname"], $username."@seat.invalid"));
			$db->execute_query("insert into user_role (user_id, role_id) values (?, ?)", array($db->insert_id, PLAYER_ROLE_ID));
			$created++;
		}

		/* Seats that are gone: deactivated, kept.
		 */
		$keep = array_keys($seats);
		if ($admin_serial !== null) {
			array_push($keep, (int)$admin_serial);
		}
		$query = "update users set status = ? where cert_serial is not null and id != ? and status != ?";
		$params = array(USER_STATUS_DISABLED, $admin["id"], USER_STATUS_DISABLED);
		if (count($keep) > 0) {
			$query .= " and cert_serial not in (".implode(", ", array_fill(0, count($keep), "?")).")";
			$params = array_merge($params, $keep);
		}
		$db->execute_query($query, $params);
		$deactivated = $db->affected_rows;

		$db->commit();
	} catch (mysqli_sql_exception $error) {
		fail("seat sync failed: ".$error->getMessage());
	}

	say(sprintf("seats: %d on the list, %d created, %d active again, %d deactivated", count($seats), $created, $reactivated, $deactivated));
