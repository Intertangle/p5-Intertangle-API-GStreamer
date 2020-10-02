use Renard::Incunabula::Common::Setup;
package Intertangle::API::GStreamer::Integration::Gtk3;
# ABSTRACT: Integrate GStreamer with Gtk3

use Mu;
use Renard::Incunabula::Common::Types qw(InstanceOf);
use Module::Load;

=classmethod set_window_handle

  classmethod set_window_handle(
      (InstanceOf['GStreamer1::Element']) $playbin,
      (InstanceOf['Gtk3::Widget']) $widget )

Set the window handle for C<$playbin> to the native handle for C<$widget>.

=cut
classmethod set_window_handle(	(InstanceOf['GStreamer1::Element']) $playbin,
	(InstanceOf['Gtk3::Widget']) $widget ) {
	autoload 'Intertangle::API::Gtk3::WindowID';

	die("Couldn't create native window needed for GstVideoOverlay!")
		unless($widget->get_window->ensure_native);

	# Retrieve window handler from GDK
	my $window_handle = Intertangle::API::Gtk3::WindowID->get_widget_id( $widget );

	# Pass it to playbin, which implements VideoOverlay and will forward it to the video sink
	$playbin->set_window_handle( $window_handle );
}

1;
