#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

# RPi::I2C is a compiled, Linux-only transport; satisfying its require
# up front keeps these validation tests runnable on any machine. Every
# path exercised here croaks before the transport would be touched

BEGIN {
    $INC{'RPi/I2C.pm'} = __FILE__;
}

use RPi::Gyro::MPU6050;

plan tests => 18;

my $ok = eval {
    RPi::Gyro::MPU6050->new(device => []);
    1;
};
is $ok, undef, "new() dies with a non-string device param";
like $@, qr/device param/, "...with a relevant error message";

$ok = eval {
    RPi::Gyro::MPU6050->new(addr => 999999);
    1;
};
is $ok, undef, "new() dies with an out of range addr param";
like $@, qr/addr param/, "...with a relevant error message";

$ok = eval {
    RPi::Gyro::MPU6050->new(addr => 0x40);
    1;
};
is $ok, undef, "new() dies with an addr this chip can never have";
like $@, qr/addr param/, "...with a relevant error message";

# A transport-less object gets us through the Perl-level validation
# without ever touching the I2C layer

my $fake = bless {}, 'RPi::Gyro::MPU6050';

eval { $fake->accel('q'); };
like $@, qr/\$axis param/, "accel() validates the axis";

eval { $fake->gyro('q'); };
like $@, qr/\$axis param/, "gyro() validates the axis";

eval { $fake->accel_range(3); };
like $@, qr/\$g param/, "accel_range() rejects an invalid range";

eval { $fake->gyro_range(123); };
like $@, qr/\$dps param/, "gyro_range() rejects an invalid range";

eval { $fake->calibrate_gyro('abc'); };
like $@, qr/\$samples param/, "calibrate_gyro() validates the sample count";

eval { $fake->calibrate_gyro(0); };
like $@, qr/\$samples param/, "calibrate_gyro() rejects a zero sample count";

eval { $fake->gyro_offsets('abc'); };
like $@, qr/\$offsets param/, "gyro_offsets() requires a hashref";

eval { $fake->gyro_offsets({ q => 1 }); };
like $@, qr/axis keys/, "gyro_offsets() rejects unknown axes";

eval { $fake->gyro_offsets({ x => 'abc' }); };
like $@, qr/x value/, "gyro_offsets() rejects non-numeric offsets";

eval { $fake->register(999); };
like $@, qr/\$reg param/, "register() validates the register";

eval { $fake->register(0, 999); };
like $@, qr/\$value param/, "register() validates the value";

eval { $fake->temp; };
like $@, qr/device has been closed/, "methods croak with no transport underneath";
