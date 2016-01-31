package MonthlyEntriesPublisher::Callbacks;

use strict;
use warnings;
use File::Spec;
use Data::Dumper;
use MT::TheSchwartz;
use TheSchwartz::Job;
use MT::Serialize;
use MT::Entry;

sub _update_entry {
    my ( $cb, $app, $obj, $original ) = @_;
    my $orig_date = $original->authored_on if defined $original;
    my $date = $obj->authored_on;
    if ( $orig_date ) {
        $orig_date =~ s/[^0-9]//g;
        $orig_date = substr( $orig_date, 0, 6 );
        $orig_date += 0;
    }
    $date =~ s/[^0-9]//g;
    $date = substr( $date, 0, 6 );
    $date += 0;
    if ( $orig_date && ( $date == $orig_date ) ) {
        $orig_date = undef;
    }
    my $callback = $cb->name;
    my $update;
    if ( $callback eq 'cms_post_delete.entry' ) {
        if ( $obj->status == MT::Entry::RELEASE() ) {
            $update = 1;
        }
    } else {
        if (! defined( $original ) ) {
            $update = 1;
        } else {
            if ( $obj->status == MT::Entry::RELEASE() ) {
                $update = 1;
            } else {
                if ( $obj->status != $original->status ) {
                    $update = 1;
                    if ( $obj->status == MT::Entry::FUTURE () ) {
                        if ( $original->status != MT::Entry::RELEASE() ) {
                            $update = undef;
                        }
                    }
                }
            }
        }
    }
    if ( $update ) {
        my $job = TheSchwartz::Job->new();
        $job->funcname( 'MonthlyEntriesPublisher::Worker::Publisher' );
        $job->uniqkey( $date );
        my $priority = 8;
        $job->priority( $priority );
        $job->coalesce( 'monthlyentriespublisher:' . $$ . ':' . ( time - ( time % 10 ) ) );
        my $grabbed = time() - 120;
        $job->run_after( $grabbed );
        $job->grabbed_until( $grabbed );
        my $data;
        my ( $start, $end ) = MT::Util::start_end_month( $obj->authored_on );
        $data->{ current_timestamp } = $start;
        $data->{ current_timestamp_end } = $end;
        $data->{ archive_date } = $date;
        my $ser = MT::Serialize->serialize( \$data );
        $job->arg( $ser );
        MT::TheSchwartz->insert( $job );
        if ( $orig_date ) {
            my $job = TheSchwartz::Job->new();
            $job->funcname( 'MonthlyEntriesPublisher::Worker::Publisher' );
            $job->uniqkey( $orig_date );
            my $priority = 8;
            $job->priority( $priority );
            $job->coalesce( 'monthlyentriespublisher:' . $$ . ':' . ( time - ( time % 10 ) ) );
            my $grabbed = time() - 120;
            $job->run_after( $grabbed );
            $job->grabbed_until( $grabbed );
            my $data;
            my ( $start, $end ) = MT::Util::start_end_month( $original->authored_on );
            $data->{ current_timestamp } = $start;
            $data->{ current_timestamp_end } = $end;
            $data->{ archive_date } = $orig_date;
            my $ser = MT::Serialize->serialize( \$data );
            $job->arg( $ser );
            MT::TheSchwartz->insert( $job );
        }
    }
    return 1;
}

sub _scheduled_update_entry {
    my ( $cb, $mt, $obj ) = @_;
    my $app = MT->instance();
    if ( $obj->class eq 'entry' ) {
        return _update_entry( $cb, $app, $obj );
    }
    1;
}

1;