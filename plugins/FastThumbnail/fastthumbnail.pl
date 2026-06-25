package MT::Plugin::FastThumbnail;

use strict;
use MT;
use MT::Plugin;

use POSIX qw( floor );

@MT::Plugin::FastThumbnail::ISA = qw(MT::Plugin);

my $PLUGIN_NAME = 'FastThumbnail';
my $VERSION = '1.3';
my $plugin = new MT::Plugin::FastThumbnail({
    name => $PLUGIN_NAME,
    version => $VERSION,
    description => '<MT_TRANS phrase="This plugin enables to speed up processing of thumbnails.">',
    doc_link => 'http://labs.m-logic.jp/plugins/fastthumbnail/docs/' . $VERSION . '/fastthumbnail.html',
    author_name => 'M-Logic, Inc.',
    author_link => 'https://m-logic.co.jp/',
    l10n_class  => 'FastThumbnail::L10N',
    registry    => {
        callbacks => {
            init_app => \&init_app
        }
    }
});

if (MT->version_number >= 7.9) { # required MT7.9
    MT->add_plugin($plugin);
}

sub instance { $plugin; }

use constant _FT_SKIPCONVERT => 0;
use constant _FT_SKIPMAGICK  => 0;

my $jpeg_quality = 85;
my $png_quality = 70;
my $has_magick = 0;
my $ft_saved_has_thumbnail;
my $ft_saved_thumbnail_file;

sub init_app {
    my ( $cb, $app ) = @_;

    eval { require Image::Magick };
    $has_magick = $@ ? 0 : 1;
    if (MT->config('ImageQualityJpeg')) {
        $jpeg_quality = MT->config('ImageQualityJpeg') || 1;
    }
    if (MT->config('ImageQualityPng')) {
        $png_quality = MT->config('ImageQualityPng') || 0;
        $png_quality = $png_quality * 10;
    }

    {
        require MT::Asset::Image;
        no warnings 'once';
        no warnings 'redefine';
        $ft_saved_has_thumbnail = \&MT::Asset::Image::has_thumbnail;
        $ft_saved_thumbnail_file = \&MT::Asset::Image::thumbnail_file;
        *MT::Asset::Image::has_thumbnail  = \&ft_has_thumbnail;
        *MT::Asset::Image::thumbnail_file = \&ft_thumbnail_file;
    }
    log_info("FastThumbnail initialized: has_magick=$has_magick jpeg_quality=$jpeg_quality png_quality=$png_quality") if $MT::DebugMode;
}

sub _log {
    my ($message, $category, $level) = @_;

    require MT::Log;
    $level ||= MT::Log::INFO();
    $message = Encode::encode_utf8($message) if Encode::is_utf8($message);
    MT->log(
        {   class    => 'system',
            category => $category,
            level    => $level,
            message  => $message,
        }
    );
    return;
}

sub log_error {
    my $message = shift;
    my $category = shift || $PLUGIN_NAME;
    return _log($message, $category, MT::Log::ERROR());
}

sub log_info {
    my $message = shift;
    my $category = shift || $PLUGIN_NAME;
    return _log($message, $category, MT::Log::INFO());
}

sub ft_has_thumbnail {
    my $asset = shift;

    my $check = MT->config('StrictImageCheck') || 0;
    if ($check == 0) {
        # Check file existence & driver support (MT7.9-)
        return unless -f $asset->file_path;
        require MT::Image;
        my $image = MT::Image->new(
            ( ref $asset ? ( Type => $asset->file_ext ) : () ) );
        return $image ? 1 : 0;
    }
    elsif ($check == 1) {
        # Check file existence & extension only (MT5.14-)
        return unless (ref $asset && -f $asset->file_path);
        my $cfg = MT->config('ImageAssetFileTypes');
        my @ext;
        if ($cfg) {
            @ext = map {qr/$_/i} split( /\s*,\s*/, $cfg );
        }
        else {
            @ext = @{$asset->extensions};
        }
        require File::Basename;
        return ( File::Basename::fileparse( $asset->file_path, @ext ) )[2] ? 1 : 0;
    }
    else {
        # No check (MT5.13)
        return 1;
    }
}

sub ft_thumbnail_file {
    my $asset = shift;
    my (%param) = @_;

    my $fmgr;
    my $blog = $param{Blog} || $asset->blog;
    require MT::FileMgr;
    $fmgr ||= $blog ? $blog->file_mgr : MT::FileMgr->new('Local');
    if (!$fmgr) {
        log_error('no FileMgr') if $MT::DebugMode;
        return undef;
    }

    my $file_path = $asset->file_path;
    if (!$fmgr->file_size($file_path)) {
        log_error('no FileSize ' . $file_path) if $MT::DebugMode;
        return undef;
    }

    require MT::Util;
    my ( $i_h, $i_w ) = ( $asset->image_height, $asset->image_width );
    if ( !defined $i_h || !defined $i_w ) {
        log_error('no ImageDimension ' . $file_path) if $MT::DebugMode;
        return undef;
    }

    require MT::Image;
    my $asset_cache_path = $asset->_make_cache_path( $param{Path} );
    # Pretend the image is already square, for calculation purposes.
    my $auto_size = 1;
    my ($r_w, $r_h);
    if ( $param{Square} ) {
        if ( $param{Width} && !$param{Height} ) {
            $param{Height} = $param{Width};
        }
        elsif ( !$param{Width} && $param{Height} ) {
            $param{Width} = $param{Height};
        }
        #
        if ( !$param{Width} && !$param{Height} ) {
            # no width/height specified
            # read original image
            $r_h = $i_h;
            $r_w = $i_w;
            my %square
                = MT::Image->inscribe_square( Width => $i_w, Height => $i_h );
            ( $i_h, $i_w ) = @square{qw( Size Size )};
            $param{Width} = $param{Height} = $i_h;
        }
        else {
            # width/height specified
            if ($i_w > $i_h) {
                # landscape
                $r_h = $param{Width} = $param{Height};
                $r_w = floor( ( $i_w * $param{Height} / $i_h ) + 0.5 );
            }
            elsif ($i_w == $i_h) {
                # square
                $r_h = $r_w = $param{Width} = $param{Height};
            }
            else {
                # portrait
                $r_w = $param{Height} = $param{Width};
                $r_h = floor( ( $i_h * $param{Width} / $i_w ) + 0.5 );
            }
        }
        $auto_size = 0;
    }
    if ( my $scale = $param{Scale} ) {
        $param{Width}  = int( ( $i_w * $scale ) / 100 );
        $param{Height} = int( ( $i_h * $scale ) / 100 );
        $auto_size     = 0;
    }
    if ( !exists $param{Width} && !exists $param{Height} ) {
        $param{Width}  = $i_w;
        $param{Height} = $i_h;
        $auto_size     = 0;
    }

    require MT::Asset::Image;
    # find the longest dimension of the image:
    my ( $n_h, $n_w, $scaled )
        = $param{Square} ? ($param{Height}, $param{Width}, undef) : MT::Asset::Image::_get_dimension( $i_h, $i_w, $param{Height}, $param{Width} );
    if ( $auto_size && $scaled eq 'h' ) {
        delete $param{Width} if exists $param{Width};
    }
    elsif ( $auto_size && $scaled eq 'w' ) {
        delete $param{Height} if exists $param{Height};
    }

    my $file = $asset->thumbnail_filename(%param) or return;
    my $thumbnail = File::Spec->catfile( $asset_cache_path, $file );

    # thumbnail file exists and is dated on or later than source image
    if ($fmgr->exists($thumbnail)
        && ( $fmgr->file_mod_time($thumbnail)
            >= $fmgr->file_mod_time($file_path) )
        )
    {
        my $already_exists = 1;
        if ( $asset->image_width != $asset->image_height ) {
            my ( $t_w, $t_h )
                = MT::Image->get_image_info( Filename => $thumbnail );
            if (   ( $param{Square} && $t_h != $t_w )
                || ( !$param{Square} && $t_h == $t_w ) )
            {
                # Check inconsistency..
                $already_exists = 0;
            }
        }
        return ( $thumbnail, $n_w, $n_h ) if $already_exists;
    }
    return if $param{NoCreate};

    # stale or non-existent thumbnail. let's create one!
    return undef unless $fmgr->can_write($asset_cache_path);

    my $convert = MT->config('ConvertPath') || '';
    $convert = '' unless -f $convert;

    my $start_process_time;
    if ($MT::DebugMode) {
        require Time::HiRes;
        $start_process_time = Time::HiRes::time();
    }
    $r_h = $n_h unless defined $r_h;
    $r_w = $n_w unless defined $r_w;
    my $data;
    if (   ( $n_w == $i_w )
        && ( $n_h == $i_h )
        && !$param{Square}
        && !$param{Type} )
    {
        $data = $fmgr->get_data( $file_path, 'upload' );
        $fmgr->put_data( $data, $thumbnail, 'upload' )
            or return $asset->error(
                MT->translate( "Error creating thumbnail file: [_1]", $fmgr->errstr )
            );
    }
    elsif (!_FT_SKIPCONVERT && $convert) {
        my $quality;
        my $ext = lc($param{Type} || $asset->file_ext || '');
        if ($ext =~ /^jpe?g$/) {
            $quality = $jpeg_quality;
        }
        elsif ($ext eq 'png') {
            $quality = $png_quality;
        }
        my $q = $quality ? " -quality $quality " : '';
        my $cmd = '"' . $convert . '"'
             . ' -size ' . $r_w . 'x' . $r_h
             . ' ' . $file_path . $q
             . ' -thumbnail ' . $r_w . 'x' . $r_h
             . ( $param{Square} ? ' -gravity center' : '' )
             . ' -extent ' . $n_w . 'x' . $n_h
             . ( $param{Type} ? ' -format ' . uc($param{Type}) : '' )
             . ' ' . $thumbnail;
        my $r;
        $r = system( $cmd );
        if ($MT::DebugMode) {
            log_info(
                'useconvert:' . $file_path . '=>' . $thumbnail . ' '
                . '/Resize:[' . $i_w . ',' . $i_h . ']=>[' . $n_w . ',' . $n_h . '] '
                . ( $param{Type} ? ('/Convert:' . $param{Type} . ' ') : '' )
                . ( $param{Square} ? ('/Square:' . $param{Square} . ' ') : '' )
                . ( $quality ? ('/Quality:' . $quality . ' ') : '' )
                . '/Result:' . ( $r ? 'failed' : 'success' ) . ' '
                . '/Time:' . (Time::HiRes::time() - $start_process_time) . 'msec'
            );
        }
    }
    elsif (!_FT_SKIPMAGICK && $has_magick) {
        my $image = Image::Magick->new();
        my $r;
        my $param = $r_w .'x' . $r_h;
        eval { $r = $image->Set(size => $param); };
        eval { $r ||= $image->Read($file_path); };
        eval { $r ||= $image->Thumbnail(width => $r_w, height => $r_h); };
        if ($param{Square} && ($n_w != $r_w || $n_h != $r_h)) {
            # make_square
            my $x = int(($r_w - $n_w) / 2);
            my $y = int(($r_h - $n_h) / 2);
            eval { $r ||= $image->Crop('width' => $n_w, 'height' => $n_h, 'x' => $x, 'y' => $y); };
        }
        if ($param{Type}) {
            my $type = uc $param{Type};
            eval { $r ||= $image->Set( magick => $type ); };
        }
        my $ext = lc($param{Type} || $asset->file_ext || '');
        my $quality;
        if ($ext =~ /^jpe?g$/) {
            eval { $r ||= $image->Set( quality => $jpeg_quality ); };
            $quality = $jpeg_quality;
        }
        elsif ($ext eq 'png') {
            eval { $r ||= $image->Set( quality => $png_quality ); };
            $quality = $png_quality;
        }
        eval { $r ||= $image->Write(filename=>$thumbnail); };
        if ($MT::DebugMode) {
            log_info(
                'usemagick:' . $file_path . '=>' . $thumbnail . ' '
                . '/Resize:[' . $i_w . ',' . $i_h . ']=>[' . $n_w . ',' . $n_h . '] '
                . ( $param{Type} ? ('/Convert:' . $param{Type} . ' ') : '' )
                . ( $param{Square} ? ('/Square:' . $param{Square} . ' ') : '' )
                . '/Result:' . ($r ? $r : 'success') . ' '
                . '/Time:' . (Time::HiRes::time() - $start_process_time) . 'sec'
            );
        }
    }
    else {
        # create a thumbnail for this file
        my $img = new MT::Image( Filename => $file_path )
            or return $asset->error( MT::Image->errstr );

        # Really make the image square, so our scale calculation works out.
        if ( $param{Square} ) {
            ($data) = $img->make_square()
                or return $asset->error(
                MT->translate( "Error cropping image: [_1]", $img->errstr ) );
        }

        ($data) = $img->scale( Height => $n_h, Width => $n_w )
            or return $asset->error(
            MT->translate( "Error scaling image: [_1]", $img->errstr ) );

        if ( my $type = $param{Type} ) {
            ($data) = $img->convert( Type => $type )
                or return $asset->error(
                MT->translate( "Error converting image: [_1]", $img->errstr )
                );
        }

        $fmgr->put_data( $data, $thumbnail, 'upload' )
            or return $asset->error(
                MT->translate( "Error creating thumbnail file: [_1]", $fmgr->errstr )
            );
        if ($MT::DebugMode) {
            log_info(
                'legacyresize:' . $file_path . '=>' . $thumbnail . ' '
                . '/Resize:[' . $i_w . ',' . $i_h . ']=>[' . $n_w . ',' . $n_h . '] '
                . ( $param{Type} ? ('/Convert:' . $param{Type} . ' ') : '' )
                . ( $param{Square} ? ('/Square:' . $param{Square} . ' ') : '' )
                . '/Result: success '
                . '/Time:' . (Time::HiRes::time() - $start_process_time) . 'sec'
            );
        }
    }
    return ( $thumbnail, $n_w, $n_h );
}

1;
