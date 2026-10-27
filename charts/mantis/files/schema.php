<?php
# Installs the MantisBT schema into an empty database, or applies any pending
# schema upgrades to an existing one, without the web installer.
#
# Run by the chart's schema Job on every install and upgrade. It is safe to run
# repeatedly: each schema step is recorded in `database_version` as it
# completes, so a re-run resumes where the last one stopped and a run against
# an up-to-date database does nothing.
#
# This is MantisBT's own admin/upgrade_unattended.php with one difference: that
# script refuses an empty database, whereas this one starts from step 0, which
# is exactly what admin/install.php does when it installs.
#
# Exit status: 0 done, 1 failed, 3 database not reachable yet.
#
# Environment:
#   MANTIS_ADMIN_PASSWORD_FILE  on a fresh install, set the password of the
#                               built-in "administrator" account from this file
#                               instead of leaving it at the well-known "root".

@set_time_limit( 0 );

# Maintenance mode: core.php loads config_inc.php but does not open the
# database or load plugins, so this works before any table exists.
define( 'MANTIS_MAINTENANCE_MODE', true );

$t_mantis_root = getenv( 'MANTIS_ROOT' ) ?: '/var/www/html/mantis';
require_once( $t_mantis_root . '/core.php' );
require_api( 'crypto_api.php' );
require_api( 'install_helper_functions_api.php' );
$g_error_send_page_header = false;

# Exit status: 0 done, 1 failed, 3 database not reachable (the caller retries).
#
# MantisBT's error handler prints the error and exits with status 0, which
# would make any fatal error inside its APIs look like success. Anything that
# ends the script before the final "Done" is therefore turned into a failure.
$g_schema_done = false;
register_shutdown_function( function() {
	global $g_schema_done;
	if( !$g_schema_done ) {
		exit( 1 );
	}
} );

function fail( $p_message, $p_status = 1 ) {
	global $g_schema_done;
	fwrite( STDERR, 'ERROR: ' . $p_message . "\n" );
	$g_schema_done = true;
	exit( $p_status );
}

# -----------------------------------------------------------------------------
# Is the database up yet? Probed with plain ADOdb, which returns false rather
# than going through MantisBT's error handler.
$t_probe = ADONewConnection( config_get_global( 'db_type' ) );
if( !@$t_probe->Connect( config_get_global( 'hostname' ), config_get_global( 'db_username' ),
		config_get_global( 'db_password' ), config_get_global( 'database_name' ) ) ) {
	fail( 'database ' . config_get_global( 'database_name' ) . ' on '
		. config_get_global( 'hostname' ) . ' is not reachable yet: ' . $t_probe->ErrorMsg(), 3 );
}
$t_probe->Close();

# Connect. db_connect() rather than a bare ADONewConnection() so the connection
# gets the same charset handling (SET NAMES UTF8 on MySQL) as the application.
$t_result = @db_connect( config_get_global( 'dsn', false ), config_get_global( 'hostname' ),
	config_get_global( 'db_username' ), config_get_global( 'db_password' ),
	config_get_global( 'database_name' ) );
if( false == $t_result ) {
	fail( 'connecting to ' . config_get_global( 'database_name' ) . ' on '
		. config_get_global( 'hostname' ) . ' failed: ' . db_error_msg() );
}
echo 'Connected to ' . config_get_global( 'db_type' ) . ' database '
	. config_get_global( 'database_name' ) . ' on ' . config_get_global( 'hostname' ) . "\n";

$GLOBALS['g_db_type'] = config_get_global( 'db_type' );
require_once( $t_mantis_root . '/admin/schema.php' );

# -----------------------------------------------------------------------------
# Where are we? No config table means an empty database.
$t_fresh = !db_table_exists( db_get_table( 'config' ) );
if( $t_fresh ) {
	$t_last_update = -1;
	echo "Empty database: installing the schema\n";
} else {
	$t_last_update = (int)config_get( 'database_version', -1, ALL_USERS, ALL_PROJECTS );
	if( -1 == $t_last_update ) {
		fail( 'the config table exists but has no database_version; this is not a '
			. 'MantisBT database this script can safely touch' );
	}
}

$t_last_id = count( $g_upgrade ) - 1;
echo 'Schema is at step ' . $t_last_update . ', latest is ' . $t_last_id . "\n";

# -----------------------------------------------------------------------------
# Apply the steps. Same dispatch as admin/install.php.
$t_failed = false;
$t_done = 0;
for( $i = $t_last_update + 1; $i <= $t_last_id && !$t_failed; $i++ ) {
	if( $g_upgrade[$i] === null ) {
		continue;
	}

	$t_dict = NewDataDictionary( $g_db );
	$t_sql = true;
	$t_operation = $g_upgrade[$i][0];
	$t_target = $g_upgrade[$i][1][0];

	switch( $t_operation ) {
		case 'InsertData':
			$t_sqlarray = call_user_func_array( $t_operation, $g_upgrade[$i][1] );
			break;
		case 'UpdateSQL':
			$t_sqlarray = array( $g_upgrade[$i][1] );
			$t_target = $g_upgrade[$i][1];
			break;
		case 'UpdateFunction':
			$t_sqlarray = array( $g_upgrade[$i][1] );
			if( isset( $g_upgrade[$i][2] ) ) {
				$t_sqlarray[] = $g_upgrade[$i][2];
			}
			$t_sql = false;
			$t_target = $g_upgrade[$i][1];
			break;
		case null:
			# A step removed from the schema, kept as a placeholder.
			$t_target = null;
			break;
		default:
			# [2] is a precondition; when it is false the step is skipped.
			if( isset( $g_upgrade[$i][2] )
				&& !call_user_func_array( $g_upgrade[$i][2][0], $g_upgrade[$i][2][1] ) ) {
				$t_target = null;
			} else {
				$t_sqlarray = call_user_func_array( array( $t_dict, $t_operation ), $g_upgrade[$i][1] );
			}
	}

	echo 'Schema step ' . $i . ': ' . ( $t_operation ?: 'no-op' );
	if( $t_target === null ) {
		$t_ret = 2;
	} else {
		echo ' ( ' . $t_target . ' )';
		if( $t_sql ) {
			$t_ret = $t_dict->ExecuteSQLArray( $t_sqlarray, false );
		} else if( isset( $t_sqlarray[1] ) ) {
			$t_ret = call_user_func( 'install_' . $t_sqlarray[0], $t_sqlarray[1] );
		} else {
			$t_ret = call_user_func( 'install_' . $t_sqlarray[0] );
		}
	}

	if( $t_ret == 2 ) {
		echo " - OK\n";
		config_set( 'database_version', $i, ALL_USERS, ALL_PROJECTS );
		$t_done++;
	} else {
		echo " - FAILED\n";
		fwrite( STDERR, ( $t_sql ? implode( "\n", $t_sqlarray ) . "\n" : '' ) . $g_db->ErrorMsg() . "\n" );
		$t_failed = true;
	}
}

if( $t_failed ) {
	fail( 'schema update stopped after ' . $t_done . ' step(s); fix the error and re-run' );
}
echo $t_done . " schema step(s) applied\n";

# -----------------------------------------------------------------------------
# The schema creates "administrator" with the password "root". Replace it, but
# only on the install that created the account: after that the password is the
# administrator's own business, not the chart's.
$t_password_file = getenv( 'MANTIS_ADMIN_PASSWORD_FILE' );
if( $t_fresh && $t_password_file && is_readable( $t_password_file ) ) {
	$t_password = trim( file_get_contents( $t_password_file ) );
	$t_user_id = user_get_id_by_name( 'administrator' );
	if( $t_user_id && $t_password !== '' ) {
		user_set_password( $t_user_id, $t_password, true );
		echo "Password set for the administrator account\n";
	}
}

echo "Done\n";
$g_schema_done = true;
exit( 0 );
