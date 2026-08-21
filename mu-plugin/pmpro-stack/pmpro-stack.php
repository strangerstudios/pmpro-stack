<?php
/**
 * PMPro Stack — main bootstrap.
 *
 * @package PMPro_Stack
 */

defined( 'ABSPATH' ) || exit;

define( 'PMPRO_STACK_VERSION', '1.1.0' );
define( 'PMPRO_STACK_DIR', __DIR__ );
define( 'PMPRO_STACK_HOSTING_URL', 'https://www.paidmembershipspro.com/hosting/' );

require_once PMPRO_STACK_DIR . '/includes/class-cache.php';
require_once PMPRO_STACK_DIR . '/includes/class-pdf-preview.php';
require_once PMPRO_STACK_DIR . '/includes/class-admin-page.php';

new PMPro_Stack_Cache();
PMPro_Stack_PDF_Preview::get_instance();

if ( is_admin() ) {
	new PMPro_Stack_Admin_Page();
}
