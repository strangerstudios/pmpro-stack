<?php
/**
 * PMPro Stack — Surge page-cache dropin.
 *
 * This file loads the Surge caching engine bundled with PMPro Stack. It is
 * installed to wp-content/advanced-cache.php and runs before plugins load, so
 * it uses WP_CONTENT_DIR-based paths rather than plugin constants.
 *
 * @package PMPro_Stack
 */

namespace Surge;

// Load PMPro Stack's Surge configuration (ignored cookies, etc.).
if ( ! defined( 'WP_CACHE_CONFIG' ) ) {
	$config_path = WP_CONTENT_DIR . '/mu-plugins/pmpro-stack/surge-config.php';
	if ( file_exists( $config_path ) ) {
		define( 'WP_CACHE_CONFIG', $config_path );
	}
}

// Point to the bundled Surge serve location.
$surge_path = WP_CONTENT_DIR . '/mu-plugins/pmpro-stack/bundled/surge/include/serve.php';
if ( file_exists( $surge_path ) ) {
	include_once $surge_path;
}
