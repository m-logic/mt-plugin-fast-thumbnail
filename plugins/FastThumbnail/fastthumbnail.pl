package MT::Plugin::FastThumbnail;

use strict;
use MT;
use MT::Plugin;

@MT::Plugin::FastThumbnail::ISA = qw(MT::Plugin);

my $PLUGIN_NAME = 'FastThumbnail';
my $VERSION = '1.2';
my $plugin = new MT::Plugin::FastThumbnail({
    name => $PLUGIN_NAME,
    version => $VERSION,
    description => '<MT_TRANS phrase="This plugin enables to speed up processing of thumbnails.">',
    doc_link => 'http://labs.m-logic.jp/plugins/fastthumbnail/docs/' . $VERSION . '/fastthumbnail.html',
    author_name => 'M-Logic, Inc.',
    author_link => 'http://m-logic.co.jp/',
    l10n_class => 'FastThumbnail::L10N',

});

require MT::Asset::Image;

if (MT->version_number >= 5.14) { # required MT5.14
    MT->add_plugin($plugin);
}

sub instance { $plugin; }

package MT::Asset::Image;

use constant _FT_DEBUG => 0;
use constant _FT_SKIPCONVERT => 0;
use constant _FT_SKIPMAGICK  => 0;

if (MT->version_number >= 5.14) { # required MT5.14

    my $jpeg_quality;
    my $png_quality;
    if (MT->version_number >= 6.2) {
        $jpeg_quality = MT->config->ImageQualityJpeg || 0;
        $png_quality = MT->config->ImageQualityPng || 0;
        unless ($jpeg_quality && $jpeg_quality =~ /^\d{1,3}$/ && $jpeg_quality <= 100) {
            $jpeg_quality = 75; # default
        }
        unless ($png_quality && $png_quality =~ /^\d{1}$/ && $png_quality <= 9) {
            $png_quality = 7; # default
        }
        # For the MNG and PNG image formats, the quality value sets the zlib compression level (quality / 10) and filter-type (quality % 10).
        # The default PNG "quality" is 75, which means compression level 7 with adaptive PNG filtering, unless the image has a color map, in which case it means compression level 7 with no PNG filtering.
        $png_quality = $png_quality * 10 + 5;
    }
    else {
        $jpeg_quality = 75;
        $png_quality = 75;
    }

    my $saved_has_thumbnail = \&MT::Asset::Image::has_thumbnail;
    my $saved_thumbnail_file = \&MT::Asset::Image::thumbnail_file;
    {
        local $SIG{__WARN__} = sub {};
        *has_thumbnail      = \&new_has_thumbnail;
        *thumbnail_file     = \&new_thumbnail_file;
    }

    sub _log {
        my ($message, $category, $level) = @_;

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

    sub new_has_thumbnail {
        my $asset = shift;
        my $check = MT->config('StrictImageCheck') || 0;
        if ($check == 0) {
            # MT5.2
            require MT::Image;
            my $image = MT::Image->new(
                ( ref $asset ? ( Filename => $asset->file_path ) : () ) );
            return $image ? 1 : 0;
        }
        elsif ($check == 1) {
            # Check file existence & extension
            return 0 unless (ref $asset && -f $asset->file_path);
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

    sub new_thumbnail_file {
        my $asset = shift;
        my (%param) = @_;
    
        my $fmgr;
        my $blog = $param{Blog} || $asset->blog;
        require MT::FileMgr;
        $fmgr ||= $blog ? $blog->file_mgr : MT::FileMgr->new('Local');
        return undef unless $fmgr;
    
        my $file_path = $asset->file_path;
        return undef unless $fmgr->file_size($file_path);
    
        require MT::Util;
        my $asset_cache_path = $asset->_make_cache_path( $param{Path} );
        my ( $i_h, $i_w ) = ( $asset->image_height, $asset->image_width );
        return undef unless $i_h && $i_w;
    
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
                require MT::Image;
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
                    $r_w = int( $i_w * $param{Height} / $i_h );
                }
                elsif ($i_w == $i_h) {
                    # square
                    $r_h = $r_w = $param{Width} = $param{Height};
                }
                else {
                    # portrait
                    $r_w = $param{Height} = $param{Width};
                    $r_h = int( $i_h * $param{Width} / $i_w );
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
    
        # find the longest dimension of the image:
        my ( $n_h, $n_w, $scaled )
            = $param{Square} ? ($param{Height}, $param{Width}, undef) : _get_dimension( $i_h, $i_w, $param{Height}, $param{Width} );
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
            my $check = MT->config('StrictImageCheck') || 0;
            my $already_exists = 1;
            if ( $check && $asset->image_width != $asset->image_height ) {
                require MT::Image;
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
    
        # stale or non-existent thumbnail. let's create one!
        return undef unless $fmgr->can_write($asset_cache_path);
    
        my $convert = MT->config('ConvertPath') || '';
        $convert = '' unless -f $convert;
        eval { require Image::Magick };
        my $has_magick = $@ ? 0 : 1;
    
        my $start_process_time;
        if (_FT_DEBUG) {
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
            if (_FT_DEBUG) {
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
            return ( $thumbnail, $n_w, $n_h );
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
            if (_FT_DEBUG) {
                log_info(
                    'usemagick:' . $file_path . '=>' . $thumbnail . ' '
                    . '/Resize:[' . $i_w . ',' . $i_h . ']=>[' . $n_w . ',' . $n_h . '] '
                    . ( $param{Type} ? ('/Convert:' . $param{Type} . ' ') : '' )
                    . ( $param{Square} ? ('/Square:' . $param{Square} . ' ') : '' )
                    . ( $quality ? ('/Quality:' . $quality . ' ') : '' )
                    . '/Result:' . ($r ? $r : 'success') . ' '
                    . '/Time:' . (Time::HiRes::time() - $start_process_time) . 'msec'
                );
            }
            return ( $thumbnail, $n_w, $n_h );
        }
        else {
            # create a thumbnail for this file
            require MT::Image;
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
        }
        $fmgr->put_data( $data, $thumbnail, 'upload' )
            or return $asset->error(
            MT->translate( "Error creating thumbnail file: [_1]", $fmgr->errstr )
            );
        if (_FT_DEBUG) {
            log_info(
                'legacyresize:' . $file_path . '=>' . $thumbnail . ' '
                . '/Resize:[' . $i_w . ',' . $i_h . ']=>[' . $n_w . ',' . $n_h . '] '
                . ( $param{Type} ? ('/Convert:' . $param{Type} . ' ') : '' )
                . ( $param{Square} ? ('/Square:' . $param{Square} . ' ') : '' )
                . '/Result: success '
                . '/Time:' . (Time::HiRes::time() - $start_process_time) . 'msec'
            );
        }
        return ( $thumbnail, $n_w, $n_h );
    }
}

1;
