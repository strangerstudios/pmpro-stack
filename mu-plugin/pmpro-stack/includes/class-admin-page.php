<?php
/**
 * PMPro Stack — admin status page.
 *
 * @package PMPro_Stack
 */

defined( 'ABSPATH' ) || exit;

/**
 * Class PMPro_Stack_Admin_Page.
 */
class PMPro_Stack_Admin_Page {

	/**
	 * Constructor.
	 */
	public function __construct() {
		add_action( 'admin_menu', array( $this, 'register' ) );
	}

	/**
	 * Register the top-level menu page.
	 *
	 * @return void
	 */
	public function register() {
		add_menu_page(
			__( 'PMPro Stack', 'pmpro-stack' ),
			__( 'PMPro Stack', 'pmpro-stack' ),
			'manage_options',
			'pmpro-stack',
			array( $this, 'render' ),
			'dashicons-performance',
			80
		);
	}

	/**
	 * Render a status indicator span.
	 *
	 * @param bool   $on      Whether the feature is on.
	 * @param string $on_text Label when on.
	 * @param string $off_text Label when off.
	 * @return string
	 */
	private function status_badge( $on, $on_text, $off_text ) {
		$color = $on ? '#1a7f37' : '#bf8700';
		$label = $on ? $on_text : $off_text;

		return sprintf(
			'<strong style="color:%1$s;">%2$s</strong>',
			esc_attr( $color ),
			esc_html( $label )
		);
	}

	/**
	 * Render the page.
	 *
	 * @return void
	 */
	public function render() {
		$cache = new PMPro_Stack_Cache();

		$object_dropin = $cache->object_cache_dropin_installed();
		$object_active = $cache->object_cache_active();
		$page_dropin   = $cache->page_cache_dropin_installed();
		$wp_cache      = $cache->wp_cache_enabled();
		?>
		<div class="wrap">
			<h1><?php esc_html_e( 'PMPro Stack', 'pmpro-stack' ); ?></h1>
			<p><?php esc_html_e( 'Performance and caching for your WordPress + Paid Memberships Pro site.', 'pmpro-stack' ); ?></p>

			<div class="card">
				<h2><?php esc_html_e( 'What is this page?', 'pmpro-stack' ); ?></h2>
				<p><?php esc_html_e( 'Your site runs on PMPro Stack — an open-source, performance-tuned server configuration for WordPress and Paid Memberships Pro. This screen is where that configuration reports in.', 'pmpro-stack' ); ?></p>
			</div>

			<div class="card">
				<h2><?php esc_html_e( "Why isn't this on the Plugins screen?", 'pmpro-stack' ); ?></h2>
				<p><?php esc_html_e( "PMPro Stack is installed as a must-use plugin: it lives in wp-content/mu-plugins/ and WordPress loads it automatically on every request. Must-use plugins can't be activated or deactivated from the Plugins screen, which is why you won't find it there. It's part of how the server is set up, not something you install per-site.", 'pmpro-stack' ); ?></p>
			</div>

			<div class="card">
				<h2><?php esc_html_e( 'What it does: caching', 'pmpro-stack' ); ?></h2>
				<p><?php esc_html_e( "Caching is one of the biggest levers on a membership site's speed, so PMPro Stack turns it on for you:", 'pmpro-stack' ); ?></p>
				<ul style="list-style:disc;margin-left:1.5em;">
					<li><?php esc_html_e( 'Object caching (Redis) — caches the results of database queries in memory, via the bundled Redis Object Cache plugin by Till Krüss. Installed as wp-content/object-cache.php.', 'pmpro-stack' ); ?></li>
					<li><?php esc_html_e( "Page caching (Surge) — serves fully-rendered pages to logged-out visitors without booting WordPress, via the bundled Surge plugin. Installed as wp-content/advanced-cache.php, and tuned to ignore PMPro's visit-tracking cookie so anonymous pages still cache.", 'pmpro-stack' ); ?></li>
				</ul>

				<table class="widefat striped" style="max-width:32em;margin-top:1em;">
					<tbody>
						<tr>
							<td><?php esc_html_e( 'Object cache dropin', 'pmpro-stack' ); ?></td>
							<td><?php echo wp_kses_post( $this->status_badge( $object_dropin, __( 'Enabled', 'pmpro-stack' ), __( 'Not installed', 'pmpro-stack' ) ) ); ?></td>
						</tr>
						<tr>
							<td><?php esc_html_e( 'Object cache active', 'pmpro-stack' ); ?></td>
							<td><?php echo wp_kses_post( $this->status_badge( $object_active, __( 'Active', 'pmpro-stack' ), __( 'Inactive', 'pmpro-stack' ) ) ); ?></td>
						</tr>
						<tr>
							<td><?php esc_html_e( 'Page cache dropin', 'pmpro-stack' ); ?></td>
							<td><?php echo wp_kses_post( $this->status_badge( $page_dropin, __( 'Enabled', 'pmpro-stack' ), __( 'Not installed', 'pmpro-stack' ) ) ); ?></td>
						</tr>
						<tr>
							<td><?php esc_html_e( 'WP_CACHE', 'pmpro-stack' ); ?></td>
							<td><?php echo wp_kses_post( $this->status_badge( $wp_cache, __( 'Enabled', 'pmpro-stack' ), __( 'Inactive', 'pmpro-stack' ) ) ); ?></td>
						</tr>
					</tbody>
				</table>
			</div>

			<div class="card" style="border-left:4px solid #2271b1;background:#f0f6fc;">
				<h2><?php esc_html_e( 'Want this managed for you?', 'pmpro-stack' ); ?></h2>
				<p><?php esc_html_e( "Want our team to manage your WordPress hosting and customizations for you? PMPro Stack is the same baseline we run for our managed-hosting customers — if you'd rather we handle the server, updates, and customizations, we offer that as a service.", 'pmpro-stack' ); ?></p>
				<p>
					<a class="button button-primary" href="<?php echo esc_url( PMPRO_STACK_HOSTING_URL ); ?>" target="_blank" rel="noopener">
						<?php esc_html_e( 'Learn more about PMPro Hosting →', 'pmpro-stack' ); ?>
					</a>
				</p>
			</div>
		</div>
		<?php
	}
}
