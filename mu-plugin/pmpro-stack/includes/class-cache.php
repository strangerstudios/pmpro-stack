<?php
/**
 * PMPro Stack — caching bootstrap and dropin management.
 *
 * Loads the bundled Redis Object Cache (Till Krüss) and Surge page cache, and
 * installs/guards their wp-content dropins (object-cache.php, advanced-cache.php).
 *
 * @package PMPro_Stack
 */

defined( 'ABSPATH' ) || exit;

/**
 * Class PMPro_Stack_Cache.
 */
class PMPro_Stack_Cache {

	/**
	 * Marker that identifies the bundled Redis Object Cache dropin.
	 */
	const OBJECT_CACHE_MARKER = 'Redis Object Cache';

	/**
	 * Constructor — bootstrap caches and schedule dropin installation.
	 */
	public function __construct() {
		$this->bootstrap_object_cache();
		$this->bootstrap_page_cache();

		add_action( 'admin_init', array( $this, 'maybe_install_dropins' ) );

		// Before PMPro's preheaders (`wp` priority 2), which can redirect and exit.
		add_action( 'wp', array( $this, 'exclude_pmpro_pages_from_cache' ), 1 );
	}

	/**
	 * Load the bundled Redis Object Cache plugin.
	 *
	 * @return void
	 */
	private function bootstrap_object_cache() {
		if ( defined( 'PMPRO_STACK_OBJECT_CACHE_LOADED' ) ) {
			return;
		}

		define( 'PMPRO_STACK_OBJECT_CACHE_LOADED', true );

		// We manage the dropin lifecycle — suppress the bundled plugin's auto-update and notices.
		defined( 'WP_REDIS_DISABLE_DROPIN_AUTOUPDATE' ) || define( 'WP_REDIS_DISABLE_DROPIN_AUTOUPDATE', true );
		defined( 'WP_REDIS_DISABLE_BANNERS' ) || define( 'WP_REDIS_DISABLE_BANNERS', true );
		defined( 'WP_REDIS_DISABLE_COMMENT' ) || define( 'WP_REDIS_DISABLE_COMMENT', true );

		$redis_cache = PMPRO_STACK_DIR . '/bundled/redis-cache/redis-cache.php';

		if ( file_exists( $redis_cache ) ) {
			require_once $redis_cache;
		}
	}

	/**
	 * Load the bundled Surge page cache plugin.
	 *
	 * @return void
	 */
	private function bootstrap_page_cache() {
		$surge = PMPRO_STACK_DIR . '/bundled/surge/surge.php';

		if ( file_exists( $surge ) ) {
			require_once $surge;
		}
	}

	/**
	 * Keep PMPro's member and checkout pages out of the page cache.
	 *
	 * Checkout and confirmation carry nonces and per-visitor state, and the
	 * account, billing, cancel, and invoice pages issue auth-dependent redirects
	 * (logged-out account -> login). Caching either serves stale nonces or a
	 * redirect loop.
	 *
	 * @link https://www.paidmembershipspro.com/documentation/advanced/caching/
	 *
	 * @return void
	 */
	public function exclude_pmpro_pages_from_cache() {
		if ( is_admin() ) {
			return;
		}

		$exclude = false;

		if ( function_exists( 'pmpro_is_checkout' ) ) {
			if ( pmpro_is_checkout() || pmpro_is_login_page() ) {
				$exclude = true;
			}

			$member_page_ids = array();
			foreach ( array( 'account', 'billing', 'cancel', 'invoice', 'confirmation' ) as $pmpro_page ) {
				$page_id = (int) get_option( 'pmpro_' . $pmpro_page . '_page_id' );
				if ( $page_id ) {
					$member_page_ids[] = $page_id;
				}
			}
			if ( $member_page_ids && is_page( $member_page_ids ) ) {
				$exclude = true;
			}
		}

		// Custom confirmation pages beyond the configured one.
		$post = get_post();
		if ( is_page() && $post && ( false !== strpos( $post->post_content, '[pmpro_confirmation' ) || has_block( 'pmpro/confirmation-page', $post ) ) ) {
			$exclude = true;
		}

		/**
		 * Filter whether the current request is excluded from the page cache.
		 *
		 * @param bool $exclude Whether to exclude the request.
		 */
		$exclude = apply_filters( 'pmpro_stack_exclude_from_cache', $exclude );

		if ( ! $exclude ) {
			return;
		}

		if ( ! defined( 'DONOTCACHEPAGE' ) ) {
			define( 'DONOTCACHEPAGE', true );
		}

		// Carry the exclusion to Cloudflare if an edge cache rule caches HTML.
		if ( ! headers_sent() ) {
			header( 'Cache-Control: no-store, no-cache, must-revalidate, max-age=0' );
		}
	}

	/**
	 * Install the wp-content dropins on admin requests.
	 *
	 * @return void
	 */
	public function maybe_install_dropins() {
		$this->install_object_cache_dropin();
		$this->install_advanced_cache_dropin();
	}

	/**
	 * Install (or refresh) the object-cache.php dropin.
	 *
	 * Never overwrites a third-party dropin; only re-copies our own dropin when
	 * the bundled source is a newer version.
	 *
	 * @return bool True if installed/refreshed, false otherwise.
	 */
	public function install_object_cache_dropin() {
		$dest   = WP_CONTENT_DIR . '/object-cache.php';
		$source = PMPRO_STACK_DIR . '/bundled/redis-cache/includes/object-cache.php';

		if ( ! file_exists( $source ) ) {
			return false;
		}

		if ( file_exists( $dest ) ) {
			$contents = file_get_contents( $dest );

			// A third-party dropin — leave it alone.
			if ( false === strpos( (string) $contents, self::OBJECT_CACHE_MARKER ) ) {
				return false;
			}

			// Ours already — only re-copy when the bundled source is newer.
			if ( ! function_exists( 'get_plugin_data' ) ) {
				require_once ABSPATH . 'wp-admin/includes/plugin.php';
			}

			$installed = get_plugin_data( $dest, false, false );
			$bundled   = get_plugin_data( $source, false, false );

			if ( version_compare( $installed['Version'], $bundled['Version'], '>=' ) ) {
				return false;
			}
		}

		return (bool) copy( $source, $dest );
	}

	/**
	 * Install the advanced-cache.php dropin.
	 *
	 * Never overwrites a third-party dropin; replaces our own in place.
	 *
	 * @return bool True on success, false otherwise.
	 */
	public function install_advanced_cache_dropin() {
		$dest   = WP_CONTENT_DIR . '/advanced-cache.php';
		$source = PMPRO_STACK_DIR . '/advanced-cache-dropin.php';

		if ( ! file_exists( $source ) ) {
			return false;
		}

		if ( file_exists( $dest ) ) {
			$contents = file_get_contents( $dest );

			// Only ours (Surge namespace or our brand) is safe to replace.
			if ( false === strpos( (string) $contents, 'namespace Surge;' ) && false === strpos( (string) $contents, 'PMPro Stack' ) ) {
				return false;
			}

			unlink( $dest );
		}

		return (bool) copy( $source, $dest );
	}

	/**
	 * Whether our object-cache.php dropin is installed.
	 *
	 * @return bool
	 */
	public function object_cache_dropin_installed() {
		$dest = WP_CONTENT_DIR . '/object-cache.php';

		if ( ! file_exists( $dest ) ) {
			return false;
		}

		return false !== strpos( (string) file_get_contents( $dest ), self::OBJECT_CACHE_MARKER );
	}

	/**
	 * Whether our advanced-cache.php (page cache) dropin is installed.
	 *
	 * @return bool
	 */
	public function page_cache_dropin_installed() {
		$dest = WP_CONTENT_DIR . '/advanced-cache.php';

		if ( ! file_exists( $dest ) ) {
			return false;
		}

		$contents = (string) file_get_contents( $dest );

		return false !== strpos( $contents, 'PMPro Stack' ) || false !== strpos( $contents, 'namespace Surge;' );
	}

	/**
	 * Whether WP_CACHE is enabled (required for the page cache dropin to load).
	 *
	 * @return bool
	 */
	public function wp_cache_enabled() {
		return defined( 'WP_CACHE' ) && WP_CACHE;
	}

	/**
	 * Whether an external object cache is active right now.
	 *
	 * @return bool
	 */
	public function object_cache_active() {
		return function_exists( 'wp_using_ext_object_cache' ) && wp_using_ext_object_cache();
	}
}
