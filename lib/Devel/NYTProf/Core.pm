# vim: ts=8 sw=4 expandtab:
##########################################################
# This script is part of the Devel::NYTProf distribution
#
# Copyright, contact and other information can be found
# at the bottom of this file, or by going to:
# http://search.cpan.org/dist/Devel-NYTProf/
#
###########################################################
# $Id: Core.pm 774 2009-06-18 20:44:25Z tim.bunce $
###########################################################
package Devel::NYTProf::Core;


use XSLoader;

our $VERSION = '2.10';    # increment with XS changes too

XSLoader::load('Devel::NYTProf', $VERSION);

if (my $NYTPROF = $ENV{NYTPROF}) {
    for my $optval ( $NYTPROF =~ /((?:[^\\:]+|\\.)+)/g) {
        my ($opt, $val) = $optval =~ /^((?:[^\\=]+|\\.)+)=((?:[^\\=]+|\\.)+)\z/;
        s/\\(.)/$1/g for $opt, $val;
        DB::set_option($opt, $val);
    }
}

1;

__END__

=head1 NAME

Devel::NYTProf::Core - load internals of Devel::NYTProf

=head1 DESCRIPTION

This module is not meant to be used directly.
See L<Devel::NYTProf>, L<Devel::NYTProf::Data>, and L<Devel::NYTProf::Reader>.

=head1 AUTHOR

B<Adam Kaplan>, C<< <akaplan at nytimes.com> >>
B<Tim Bunce>, L<http://www.tim.bunce.name> and L<http://blog.timbunce.org>
B<Steve Peters>, C<< <steve at fisharerojo.org> >>

=head1 COPYRIGHT AND LICENSE

  Copyright (C) 2008 by Adam Kaplan and The New York Times Company.
  Copyright (C) 2008 by Tim Bunce.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
