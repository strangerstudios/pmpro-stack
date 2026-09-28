<?php
/**
 * Plugin Name: PMPro Stack
 * Description: Caching + performance for WordPress + Paid Memberships Pro.
 * Version: 1.2.0
 * License: GPL-2.0+
 *
 * @package PMPro_Stack
 */

defined( 'ABSPATH' ) || exit;

$pmpro_stack_main = __DIR__ . '/pmpro-stack/pmpro-stack.php';

if ( file_exists( $pmpro_stack_main ) ) {
	require_once $pmpro_stack_main;
}
