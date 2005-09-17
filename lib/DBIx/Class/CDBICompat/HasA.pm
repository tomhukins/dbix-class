package DBIx::Class::CDBICompat::HasA;

use strict;
use warnings;

sub has_a {
  my ($self, $col, $f_class, %args) = @_;
  $self->throw( "No such column ${col}" ) unless $self->_columns->{$col};
  eval "require $f_class";
  if ($args{'inflate'} || $args{'deflate'}) { # Non-database has_a
    if (!ref $args{'inflate'}) {
      my $meth = $args{'inflate'};
      $args{'inflate'} = sub { $f_class->$meth(shift); };
    }
    if (!ref $args{'deflate'}) {
      my $meth = $args{'deflate'};
      $args{'deflate'} = sub { shift->$meth; };
    }
    $self->inflate_column($col, \%args);
    return 1;
  }
  my ($pri, $too_many) = keys %{ $f_class->_primaries };
  $self->throw( "has_a only works with a single primary key; ${f_class} has more. try using a has_one relationship instead of Class::DBI compat rels" )
    if $too_many;

  $self->has_one($col, $f_class);
  return 1;
}

1;
