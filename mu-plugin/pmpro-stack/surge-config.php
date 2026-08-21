<?php
/**
 * Surge cache configuration for PMPro Stack.
 *
 * Loaded via WP_CACHE_CONFIG. Returns an array merged with Surge defaults.
 * The $config variable contains the current defaults and is available
 * because this file is included inside Surge's config() closure.
 *
 * @package PMPro_Stack
 */

$ignore = $config['ignore_cookies'];

// Source Buster JS (sbjs) analytics cookies — unique per visitor.
$ignore[] = 'sbjs_current';
$ignore[] = 'sbjs_current_add';
$ignore[] = 'sbjs_first';
$ignore[] = 'sbjs_first_add';
$ignore[] = 'sbjs_migrations';
$ignore[] = 'sbjs_session';
$ignore[] = 'sbjs_udata';

// PMPro Visits Report dedup cookie. PMPro core skips emitting this cookie
// when WP_CACHE is true, but pre-existing browsers still send it until it
// expires; ignoring it on the request side keeps the cache key clean.
$ignore[] = 'pmpro_visit';

return array(
	'ttl'            => 43200,
	'ignore_cookies' => $ignore,
);
