package RPi::Gyro::MPU6050::Deadband;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(looks_like_number);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;

    if (! defined $args{threshold}
        || ! looks_like_number($args{threshold})
        || $args{threshold} < 0)
    {
        croak "new() requires the threshold param, a non-negative number";
    }

    $self->{threshold} = $args{threshold};

    $args{window} //= 1;

    if ($args{window} !~ /^\d+$/ || $args{window} < 1){
        croak "new() window param must be a positive integer";
    }

    $self->{window} = $args{window};

    $self->reset;

    return $self;
}
sub changed {
    my ($self) = @_;
    return $self->{changed};
}
sub reset {
    my ($self) = @_;

    $self->{history}  = [];
    $self->{reported} = undef;
    $self->{changed}  = 0;

    return 1;
}
sub threshold {
    my ($self) = @_;
    return $self->{threshold};
}
sub update {
    my ($self, $value) = @_;

    if (! defined $value || ! looks_like_number($value)){
        croak "update() requires a numeric value";
    }

    # Slide the value into the window and average it - the "last X checks".
    # A window of 1 is no smoothing (the mean of one value is the value).

    push @{ $self->{history} }, $value;
    shift @{ $self->{history} } while @{ $self->{history} } > $self->{window};

    my $sum = 0;
    $sum += $_ for @{ $self->{history} };

    my $smoothed = $sum / @{ $self->{history} };

    # Report a change only when the smoothed value has left the +/- threshold
    # band around the last value we reported (hysteresis). The first update
    # always reports, establishing the baseline.

    if (! defined $self->{reported}
        || abs($smoothed - $self->{reported}) > $self->{threshold})
    {
        $self->{reported} = $smoothed;
        $self->{changed}  = 1;
    }
    else {
        $self->{changed} = 0;
    }

    return $self->{reported};
}
sub value {
    my ($self) = @_;
    return $self->{reported};
}
sub window {
    my ($self) = @_;
    return $self->{window};
}

1;

__END__

=head1 NAME

RPi::Gyro::MPU6050::Deadband - Suppress insignificant changes in a noisy value

=head1 SYNOPSIS

    use RPi::Gyro::MPU6050::Deadband;

    # Ignore moves of 1.0 or less; average over the last 5 samples
    my $filter = RPi::Gyro::MPU6050::Deadband->new(
        threshold => 1.0,
        window    => 5,
    );

    # Feed every reading in; act only when it has really moved
    for my $reading (@stream) {
        my $settled = $filter->update($reading);
        next if ! $filter->changed;
        printf "moved to %.2f\n", $settled;
    }

Guarding an OLED (or a log, or a network push) against sensor jitter - one
filter per axis, redraw only when something actually moved:

    use RPi::Gyro::MPU6050;

    my $mpu = RPi::Gyro::MPU6050->new;

    # deadband() is a factory on the sensor object (see RPi::Gyro::MPU6050)
    my %gyro = map {
        $_ => $mpu->deadband(threshold => 1.0, window => 5)
    } qw(x y z);

    while (1) {
        my ($gx, $gy, $gz) = $mpu->gyro;

        $gyro{x}->update($gx);
        $gyro{y}->update($gy);
        $gyro{z}->update($gz);

        # redraw only when at least one axis has actually moved
        next if ! grep { $_->changed } values %gyro;

        printf "gyro %.1f %.1f %.1f dps\n",
            $gyro{x}->value, $gyro{y}->value, $gyro{z}->value;
    }

=head1 DESCRIPTION

A tiny, hardware-free helper that tells you when a noisy numeric stream has
B<meaningfully> changed, so a consumer can skip needless work (redraws, log
lines, network traffic) while the sensor is essentially still.

It combines two ideas:

=over 4

=item * a B<window> - the reading is averaged over the last C<window> samples,
so a single noise spike barely moves it; and

=item * a B<threshold> - a change is only reported once the (smoothed) value
leaves the C<+/- threshold> band around the last value that was reported
(hysteresis), which also lets slow genuine drift through eventually.

=back

It tracks a single scalar stream; compose one per axis or field. It never
reads hardware - feed it values from wherever (C<gyro()>, C<accel()>,
C<temp()>, or anything else).

=head1 METHODS

=head2 new

Returns a new filter. Parameters are sent in as a hash:

Parameters (hash):

    threshold

Mandatory, Number: the C<+/-> deadband. Changes of this size or smaller are
suppressed. Must be non-negative. Units are yours - pick per field (eg. ~1.0
for gyro deg/s, ~0.02 for accel g).

    window

Optional, Integer: how many recent samples to average before comparing.
Defaults to C<1> (no smoothing). Larger values reject brief noise spikes at
the cost of a little lag.

=head2 update

Feeds one reading (C<$value>) in. Returns the current I<reported> (smoothed)
value, and sets L</changed> for this update.

=head2 changed

Returns true if the most recent L</update> reported a change (the value left
its band, or it was the first reading), false otherwise.

=head2 value

Returns the current reported value - the last smoothed value that crossed the
threshold. C<undef> before the first L</update>.

=head2 threshold

Returns the configured threshold.

=head2 window

Returns the configured window size.

=head2 reset

Forgets all history and the reported value, as if freshly constructed. Returns
C<1>.

=head1 SEE ALSO

L<RPi::Gyro::MPU6050>, whose C<deadband()> method is a convenience factory for
these objects.

=head1 AUTHOR

Steve Bertrand, C<< <steveb at cpan.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Steve Bertrand.

This program is free software; you can redistribute it and/or modify it under
the terms of the the Artistic License (2.0).

=cut
