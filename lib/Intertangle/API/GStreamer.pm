use Renard::Incunabula::Common::Setup;
package Intertangle::API::GStreamer;
# ABSTRACT: Setup GStreamer

use strict;
use warnings;

use GStreamer1;

fun import(@) {
	for my $name ('Video') {
		my $basename = 'Gst' . $name;
		my $pkg      = $name
		? 'GStreamer1::' . $name
		: 'GStreamer1';
		Glib::Object::Introspection->setup(
			basename => $basename,
			version  => '1.0',
			package  => $pkg,
		);
	}
}



1;
=head1 SEE ALSO



=cut
