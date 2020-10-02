#!/usr/bin/env perl

use Test::Most tests => 1;
use Test::Needs qw(Gtk3);
use Module::Load;

use Renard::Incunabula::Common::Setup;
use Intertangle::API::GStreamer;
use GStreamer1;

subtest "Test Gtk3 integration" => fun() {
	autoload 'Gtk3';
	load 'Intertangle::API::GStreamer::Integration::Gtk3';

	Gtk3::init();
	GStreamer1::init([$0, @ARGV ]);

	my $window = Gtk3::Window->new;
	$window->show;
	my $pipeline = GStreamer1::parse_launch( "playbin" );
	lives_ok {
		Intertangle::API::GStreamer::Integration::Gtk3->set_window_handle( $pipeline, $window );
	};
};

done_testing;
