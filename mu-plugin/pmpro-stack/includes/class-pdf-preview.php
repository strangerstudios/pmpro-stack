<?php
/**
 * PDF preview generation via poppler's pdftoppm.
 *
 * The hardened ImageMagick policy deployed by the ansible php role denies
 * the PDF coder and the Ghostscript delegate behind it, so
 * WP_Image_Editor_Imagick can no longer rasterize PDF uploads (core fails
 * quietly and skips the preview). This class regenerates what core would
 * have produced: page 1 rendered to a `-pdf.jpg` full preview, then core's
 * own subsize machinery for the thumbnail/medium/large derivatives. Output
 * naming, filter behavior, and metadata shape mirror
 * wp_generate_attachment_metadata()'s PDF branch exactly, so downstream
 * consumers (media library, document plugins) see no difference.
 *
 * Degrades to a no-op when pdftoppm is absent (local dev without the
 * ansible roles) or when another editor already produced sizes.
 *
 * @package PMPro_Stack
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Class PMPro_Stack_PDF_Preview
 */
class PMPro_Stack_PDF_Preview {

	/**
	 * Singleton instance.
	 *
	 * @var PMPro_Stack_PDF_Preview|null
	 */
	private static $instance = null;

	/**
	 * Hard wall for the pdftoppm render, in seconds.
	 *
	 * @var int
	 */
	const RENDER_TIMEOUT = 20;

	/**
	 * Hard wall for the pdfinfo geometry read, in seconds. Lower than the
	 * render wall: this only parses the xref and first page dict, so the
	 * worst case for both commands stays well inside the stack's 60s
	 * max_execution_time default.
	 *
	 * @var int
	 */
	const INFO_TIMEOUT = 10;

	/**
	 * Render resolution in DPI. Matches WP_Image_Editor_Imagick::pdf_setup().
	 *
	 * @var int
	 */
	const RESOLUTION = 128;

	/**
	 * Longest allowed output edge in pixels. A crafted page geometry cannot
	 * demand an unbounded raster: the render DPI is scaled down to fit.
	 *
	 * @var int
	 */
	const MAX_EDGE_PX = 4096;

	/**
	 * Maximum retained stderr bytes per command (the pipe is still drained
	 * past this, so the child never blocks on a full pipe buffer).
	 *
	 * @var int
	 */
	const MAX_STDERR_BYTES = 8192;

	/**
	 * Maximum retained stdout bytes per command. Larger than the stderr cap
	 * because stdout carries data to parse: pdfinfo prints Title/Author/
	 * Keywords/Producer and friends BEFORE the "Page size:" line, and those
	 * fields are arbitrary-length, so a small cap could truncate the line
	 * the geometry read depends on.
	 *
	 * @var int
	 */
	const MAX_STDOUT_BYTES = 262144;

	/**
	 * Bytes per pipe read. Caps peak allocation while draining.
	 *
	 * @var int
	 */
	const CHUNK_BYTES = 8192;

	/**
	 * Maximum reads per drain pass, so a flooding child cannot spin one
	 * pass indefinitely (the outer poll loop resumes draining).
	 *
	 * @var int
	 */
	const MAX_CHUNKS_PER_DRAIN = 256;

	/**
	 * Address-space cap for the poppler children, in bytes (1 GiB). PHP's
	 * memory_limit does not apply to child processes, and a malformed PDF
	 * can balloon pdfinfo/pdftoppm long before the wall-clock timeout
	 * fires; prlimit turns that into a clean child failure instead of
	 * host memory pressure. Generous relative to a legitimate worst case
	 * (a MAX_EDGE_PX render needs well under 200 MB).
	 *
	 * @var int
	 */
	const AS_LIMIT_BYTES = 1073741824;

	/**
	 * Get the singleton instance.
	 *
	 * @return PMPro_Stack_PDF_Preview
	 */
	public static function get_instance() {
		if ( null === self::$instance ) {
			self::$instance = new self();
		}
		return self::$instance;
	}

	/**
	 * Constructor. Registers the metadata filter.
	 */
	private function __construct() {
		add_filter( 'wp_generate_attachment_metadata', array( $this, 'maybe_generate_preview' ), 10, 3 );
	}

	/**
	 * Resolve the pdftoppm binary path.
	 *
	 * @return string
	 */
	private function get_binary() {
		return defined( 'PMPRO_STACK_PDFTOPPM_PATH' ) ? PMPRO_STACK_PDFTOPPM_PATH : '/usr/bin/pdftoppm';
	}

	/**
	 * Resolve the pdfinfo binary path.
	 *
	 * Explicit constant wins; otherwise prefer pdftoppm's sibling (keeps a
	 * relocated poppler self-consistent, e.g. Homebrew on local dev) and
	 * fall back to the distro path.
	 *
	 * @return string
	 */
	private function get_info_binary() {
		if ( defined( 'PMPRO_STACK_PDFINFO_PATH' ) ) {
			return PMPRO_STACK_PDFINFO_PATH;
		}

		$sibling = dirname( $this->get_binary() ) . '/pdfinfo';

		return is_executable( $sibling ) ? $sibling : '/usr/bin/pdfinfo';
	}

	/**
	 * Filter callback: generate the PDF preview sizes core could not.
	 *
	 * Runs after core's PDF branch. When Imagick (or another editor) already
	 * produced sizes, or the attachment is not a PDF, this is a pass-through.
	 *
	 * @param array  $metadata      Attachment metadata.
	 * @param int    $attachment_id Attachment post ID.
	 * @param string $context       'create' or 'update'.
	 * @return array Attachment metadata, with preview sizes when generated.
	 */
	public function maybe_generate_preview( $metadata, $attachment_id, $context = 'create' ) {
		if ( ! is_array( $metadata ) ) {
			$metadata = array();
		}

		if ( 'application/pdf' !== get_post_mime_type( $attachment_id ) ) {
			return $metadata;
		}

		if ( ! empty( $metadata['sizes'] ) ) {
			return $metadata;
		}

		$binary = $this->get_binary();
		if ( ! is_executable( $binary ) ) {
			return $metadata;
		}

		// Core's PDF fallback sizes, filtered identically and BEFORE any
		// rasterization: an empty result means "no PDF previews" (core skips
		// the editor entirely in that case), so honor it the same way.
		$fallback_sizes = array( 'thumbnail', 'medium', 'large' );
		/** This filter is documented in wp-admin/includes/image.php */
		$fallback_sizes = apply_filters( 'fallback_intermediate_image_sizes', $fallback_sizes, $metadata );

		if ( ! function_exists( 'wp_get_registered_image_subsizes' ) || ! function_exists( '_wp_make_subsizes' ) ) {
			return $metadata;
		}

		$merged_sizes = array_intersect_key( wp_get_registered_image_subsizes(), array_flip( $fallback_sizes ) );
		if ( empty( $merged_sizes ) ) {
			return $metadata;
		}

		// Force thumbnails to be soft crops, as core does for PDFs.
		if ( isset( $merged_sizes['thumbnail'] ) && is_array( $merged_sizes['thumbnail'] ) ) {
			$merged_sizes['thumbnail']['crop'] = false;
		}

		$file = get_attached_file( $attachment_id );
		if ( ! $file || ! is_readable( $file ) ) {
			return $metadata;
		}

		// Mirror core's preview naming: unique `-pdf.jpg` beside the PDF, so
		// a preview never overwrites a JPEG that shares the PDF's basename.
		$dirname      = dirname( $file ) . '/';
		$ext          = '.' . pathinfo( $file, PATHINFO_EXTENSION );
		$preview_name = wp_unique_filename( $dirname, wp_basename( $file, $ext ) . '-pdf.jpg' );
		$preview_file = $dirname . $preview_name;

		if ( ! $this->rasterize_first_page( $file, $preview_file ) ) {
			return $metadata;
		}

		$dims = wp_getimagesize( $preview_file );
		if ( ! $dims ) {
			@unlink( $preview_file ); // phpcs:ignore WordPress.PHP.NoSilencedErrors.Discouraged
			return $metadata;
		}

		// Match the permissions the WP image editors set on their output.
		$stat = stat( $dirname );
		if ( false !== $stat ) {
			@chmod( $preview_file, $stat['mode'] & 0000666 ); // phpcs:ignore WordPress.PHP.NoSilencedErrors.Discouraged
		}

		$metadata['sizes'] = array(
			'full' => array(
				'file'      => $preview_name,
				'width'     => $dims[0],
				'height'    => $dims[1],
				'mime-type' => 'image/jpeg',
				'filesize'  => (int) filesize( $preview_file ),
			),
		);

		// Save before subsizing, as core does, so a mid-subsize failure
		// still leaves a usable full preview.
		wp_update_attachment_metadata( $attachment_id, $metadata );

		$metadata = _wp_make_subsizes( $merged_sizes, $preview_file, $metadata, $attachment_id );

		return $metadata;
	}

	/**
	 * Render page 1 of a PDF to a JPEG via pdftoppm.
	 *
	 * The render DPI starts at RESOLUTION (core's own PDF DPI) and is scaled
	 * down when the page geometry would exceed MAX_EDGE_PX on its longest
	 * edge, so a crafted CropBox cannot demand an unbounded raster. Page
	 * geometry comes from pdfinfo; an unparseable document is skipped.
	 *
	 * @param string $pdf_file     Absolute path to the source PDF.
	 * @param string $preview_file Absolute target path ending in .jpg.
	 * @return bool Whether the preview file was produced.
	 */
	private function rasterize_first_page( $pdf_file, $preview_file ) {
		$dpi = $this->get_bounded_dpi( $pdf_file );
		if ( ! $dpi ) {
			return false;
		}

		// pdftoppm -singlefile appends .jpg to the output root itself.
		$output_root = preg_replace( '/\.jpg$/', '', $preview_file );

		$result = $this->exec(
			array(
				$this->get_binary(),
				'-jpeg',
				'-jpegopt',
				'quality=82',
				'-r',
				(string) $dpi,
				'-f',
				'1',
				'-l',
				'1',
				'-singlefile',
				'-cropbox',
				$pdf_file,
				$output_root,
			),
			self::RENDER_TIMEOUT
		);

		if ( 0 !== $result['exitcode'] || ! file_exists( $preview_file ) ) {
			$this->log( sprintf( 'pdftoppm failed (exit %d) on %s: %s', $result['exitcode'], wp_basename( $pdf_file ), trim( $result['stderr'] ) ) );
			@unlink( $preview_file ); // phpcs:ignore WordPress.PHP.NoSilencedErrors.Discouraged
			return false;
		}

		return true;
	}

	/**
	 * Compute a render DPI bounded by MAX_EDGE_PX for the PDF's first page.
	 *
	 * @param string $pdf_file Absolute path to the source PDF.
	 * @return int|false DPI to render at, or false to skip the preview.
	 */
	private function get_bounded_dpi( $pdf_file ) {
		$pdfinfo = $this->get_info_binary();
		if ( ! is_executable( $pdfinfo ) ) {
			return false;
		}

		$result = $this->exec( array( $pdfinfo, '-f', '1', '-l', '1', $pdf_file ), self::INFO_TIMEOUT );
		if ( 0 !== $result['exitcode'] ) {
			$this->log( sprintf( 'pdfinfo failed (exit %d) on %s: %s', $result['exitcode'], wp_basename( $pdf_file ), trim( $result['stderr'] ) ) );
			return false;
		}

		// "Page    1 size: 612 x 792 pts (letter)" (or unnumbered "Page size:").
		if ( ! preg_match( '/^Page(?:\s+1)?\s+size:\s+([0-9.]+)\s+x\s+([0-9.]+)\s+pts/m', $result['stdout'], $m ) ) {
			$this->log( sprintf( 'pdfinfo page size unparseable for %s', wp_basename( $pdf_file ) ) );
			return false;
		}

		$max_pts = max( (float) $m[1], (float) $m[2] );
		if ( $max_pts <= 0 ) {
			return false;
		}

		$dpi = (int) min( self::RESOLUTION, floor( self::MAX_EDGE_PX * 72 / $max_pts ) );

		return ( $dpi >= 1 ) ? $dpi : false;
	}

	/**
	 * Run an external command with no shell and a hard timeout.
	 *
	 * stdout/stderr are drained continuously (a full pipe buffer would
	 * block the child) but retained only up to their per-stream caps.
	 *
	 * @param string[] $command Argument vector; element 0 is the binary.
	 * @param int      $timeout Hard wall in seconds.
	 * @return array{exitcode: int, stdout: string, stderr: string}
	 */
	private function exec( $command, $timeout ) {
		$result = array(
			'exitcode' => -1,
			'stdout'   => '',
			'stderr'   => '',
		);

		// Cap the child's address space and CPU when prlimit is available
		// (util-linux, present on the stack); prlimit exec()s the target, so
		// exit codes and pipes pass through unchanged.
		if ( is_executable( '/usr/bin/prlimit' ) ) {
			$command = array_merge(
				array(
					'/usr/bin/prlimit',
					'--as=' . self::AS_LIMIT_BYTES,
					'--cpu=' . (int) $timeout,
					'--',
				),
				$command
			);
		}

		$pipes   = array();
		$process = proc_open( // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions.system_calls_proc_open
			$command,
			array(
				1 => array( 'pipe', 'w' ),
				2 => array( 'pipe', 'w' ),
			),
			$pipes
		);
		if ( ! is_resource( $process ) ) {
			return $result;
		}

		stream_set_blocking( $pipes[1], false );
		stream_set_blocking( $pipes[2], false );

		$deadline = time() + $timeout;
		while ( true ) {
			$this->drain( $pipes[1], $result['stdout'], self::MAX_STDOUT_BYTES );
			$this->drain( $pipes[2], $result['stderr'], self::MAX_STDERR_BYTES );

			$status = proc_get_status( $process );
			if ( ! $status['running'] ) {
				// Only the first non-running proc_get_status() carries the real exit code.
				$result['exitcode'] = $status['exitcode'];
				break;
			}
			if ( time() > $deadline ) {
				proc_terminate( $process, 9 );
				$result['stderr'] .= sprintf( ' [killed after %ds]', $timeout );
				break;
			}
			usleep( 100000 );
		}

		$this->drain( $pipes[1], $result['stdout'], self::MAX_STDOUT_BYTES );
		$this->drain( $pipes[2], $result['stderr'], self::MAX_STDERR_BYTES );
		fclose( $pipes[1] );
		fclose( $pipes[2] );
		proc_close( $process );

		return $result;
	}

	/**
	 * Drain a pipe in fixed-size chunks, retaining output up to $limit.
	 *
	 * Reads past the retention limit are discarded rather than skipped: the
	 * pipe must keep draining or the child blocks on a full buffer.
	 *
	 * @param resource $pipe   Readable stream.
	 * @param string   $buffer Accumulator, modified in place.
	 * @param int      $limit  Maximum bytes to retain in $buffer.
	 * @return void
	 */
	private function drain( $pipe, &$buffer, $limit ) {
		for ( $i = 0; $i < self::MAX_CHUNKS_PER_DRAIN; $i++ ) {
			$chunk = fread( $pipe, self::CHUNK_BYTES );
			if ( false === $chunk || '' === $chunk ) {
				return;
			}

			$room = $limit - strlen( $buffer );
			if ( $room > 0 ) {
				$buffer .= substr( $chunk, 0, $room );
			}
		}
	}

	/**
	 * Log a failure to the PHP error log.
	 *
	 * @param string $message Log line.
	 * @return void
	 */
	private function log( $message ) {
		error_log( 'pmpro-stack pdf-preview: ' . $message ); // phpcs:ignore WordPress.PHP.DevelopmentFunctions.error_log_error_log
	}
}
