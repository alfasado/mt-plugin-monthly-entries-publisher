package MonthlyEntriesPublisher::Worker::Publisher;

use strict;
use base qw( TheSchwartz::Worker );
use MT::Serialize;
use MT::FileMgr;
use File::Basename;

use TheSchwartz::Job;
sub keep_exit_status_for {1}
sub grab_for             {60}
sub max_retries          {40}
sub retry_delay          {10}

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $component = MT->component( 'MonthlyEntriesPublisher' );
    my @jobs;
    push @jobs, $job;
    if ( my $key = $job->coalesce ) {
        while ( my $job = MT::TheSchwartz->instance->find_job_with_coalescing_value( $class, $key ) ) {
            push @jobs, $job;
        }
    }
    my $app = MT->instance();
    my $config_setting_value = MT->config( 'MonthlyEntriesPublisherTemplateIds' );
    my $begin = quotemeta( MT->config( 'MonthlyEntriesPublisherCountBegin' ) );
    my $end = quotemeta( MT->config( 'MonthlyEntriesPublisherCountEnd' ) );
    my @tmpl_ids = split( /\s*,\s*/, $config_setting_value );
    foreach $job ( @jobs ) {
        my $arg = $job->arg;
        my $data = MT::Serialize->unserialize( $arg );
        my $current_timestamp = $$data->{ current_timestamp };
        my $current_timestamp_end = $$data->{ current_timestamp_end };
        my $result;
        my $error;
        for my $id( @tmpl_ids ) {
            my $tmpl = MT->model( 'template' )->load( $id );
            if ( $tmpl ) {
                my @maps =  MT->model( 'templatemap' )->load( { template_id => $id } );
                for my $map ( @maps ) {
                    my $file = _get_monthly_archive_file( $map, $current_timestamp );
                    my $blog = MT->model( 'blog' )->lookup( $map->blog_id );
                    my $site_path = $blog->site_path;
                    my $site_url = $blog->site_url;
                    if ( $site_path !~ m/\/$/ ) {
                        $site_path .= '/';
                    }
                    my $url = $site_url . $file;
                    $url =~ s/^https{0,1}:\/\/.*?(\/)/$1/;
                    $file = $site_path . $file;
                    my $at = $map->archive_type;;
                    my $fileinfo = MT->model( 'fileinfo' )->get_by_key(
                        {
                          blog_id => $blog->id,
                          file_path => $file,
                          url => $url,
                          archive_type => $map->archive_type,
                          startdate => $current_timestamp,
                          template_id => $tmpl->id,
                          templatemap_id => $map->id,
                        }
                    );
                    require MT::Template::Context;
                    my $ctx = MT::Template::Context->new;
                    $ctx->{ current_archive_type } = $at;
                    $ctx->{ archive_type }         = $at;
                    $ctx->stash( 'blog', $blog );
                    my $archiver = MT->publisher->archiver( $at );
                    local $ctx->{ archive_type } = $at;
                    $ctx->{ current_timestamp } = $current_timestamp;
                    $ctx->{ current_timestamp_end } = $current_timestamp_end;
                    my $res = $tmpl->build( $ctx );
                    my $count = $res;
                    $count =~ s/^.*?$begin(.*?)$end.*$/$1/si;
                    $count += 0;
                    $res =~ s/$begin.*?$end//si;
                    my $fmgr = MT::FileMgr->new( 'Local' )
                        or die MT::FileMgr->errstr;
                    if ( $count ) {
                        $fileinfo->save or die $fileinfo->errstr;
                        my $path = File::Basename::dirname( $file );
                        $path =~ s!/$!!
                            unless $path eq '/';
                        if (! $fmgr->exists( $path ) ) {
                            if (! $fmgr->mkpath( $path ) ) {
                                die $app->trans_error( "Error making path '[_1]': [_2]",
                                    $path, $fmgr->errstr );
                            }
                        }
                        my $bytes = $fmgr->put_data( $res, $file );
                        if (! defined( $bytes ) ) {
                            $error = 1;
                        }
                    } else {
                        if ( $fileinfo->id ) {
                            $fileinfo->remove or die $fileinfo->errstr;
                        }
                        if ( $fmgr->exists( $file ) ) {
                            $fmgr->delete( $file );
                        }
                    }
                }
            }
        }
        if ( $error ) {
            $job->failed();
        } else {
            $job->completed();
        }
    }
    return $job->completed();
}

sub _get_monthly_archive_file {
    my ( $map, $timestamp ) = @_;
    require MT::Template::Context;
    my $ctx = MT::Template::Context->new;
    my $at = $map->archive_type;;
    $ctx->{ current_archive_type } = $at;
    $ctx->{ archive_type }         = $at;
    my $blog = MT->model( 'blog' )->lookup( $map->blog_id );
    $ctx->stash( 'blog', $blog );
    my $archiver = MT->publisher->archiver( $at );
    local $ctx->{ archive_type } = $at;
    my $file_tmpl = $map->file_template;
    if ( $file_tmpl =~ m/\%[_-]?[A-Za-z]/ ) {
        if ( $file_tmpl =~ m/<\$?mt/i ) {
            $file_tmpl
                =~ s!(<\$?mt[^>]+?>)|(%[_-]?[A-Za-z])!$1 ? $1 : '<mt:FileTemplate format="'. $2 . '">'!gie;
        } else {
            $file_tmpl = qq{<mt:FileTemplate format="$file_tmpl">};
        }
        my $file = $archiver->archive_file(
            $ctx,
            Timestamp => $timestamp,
            Template  => $file_tmpl
        );
        if ( $file_tmpl && !$file ) {
            require MT::Builder;
            my $build  = MT::Builder->new;
            my $tokens = $build->compile( $ctx, $file_tmpl )
                or return $blog->error( $build->errstr() );
            defined( $file = $build->build( $ctx, $tokens ) )
                or return $blog->error( $build->errstr() );
        } else {
            my $ext = $blog->file_extension;
            $file .= '.' . $ext if $ext;
        }
        return $file;
    }
    return undef;
}

1;