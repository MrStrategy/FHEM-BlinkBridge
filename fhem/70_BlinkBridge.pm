##############################################
# FHEM module for the FHEM-BlinkBridge HTTP bridge.

package main;

use strict;
use warnings;
use HttpUtils;
use JSON::PP ();
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(gettimeofday);

our $readingFnAttributes;
our %defs;
our $init_done;

my $BlinkBridge_Version = '0.1.0';
my $BlinkBridge_DefaultInterval = 60;
my $BlinkBridge_DefaultTimeout = 15;
my $BlinkBridge_DefaultImagePath = '/tmp';

sub BlinkBridge_Initialize {
  my ($hash) = @_;

  $hash->{DefFn}    = 'BlinkBridge_Define';
  $hash->{UndefFn}  = 'BlinkBridge_Undef';
  $hash->{DeleteFn} = 'BlinkBridge_Delete';
  $hash->{SetFn}    = 'BlinkBridge_Set';
  $hash->{GetFn}    = 'BlinkBridge_Get';
  $hash->{AttrFn}   = 'BlinkBridge_Attr';
  $hash->{AttrList} = 'disable:0,1 disabledForIntervals interval timeout imagePath ' . $readingFnAttributes;

  return undef;
}

sub BlinkBridge_Define {
  my ($hash, $def) = @_;
  my @a = split(/\s+/, $def);

  return 'Wrong syntax: use define <name> BlinkBridge <bridgeUrl> [interval]'
    if @a < 3 || @a > 4;

  my ($name, undef, $baseUrl, $interval) = @a;
  return 'bridgeUrl must start with http:// or https://'
    if $baseUrl !~ m{^https?://}i;

  $baseUrl =~ s{/+$}{};
  $hash->{BASE_URL} = $baseUrl;
  $hash->{VERSION} = $BlinkBridge_Version;
  $hash->{INTERVAL} = defined($interval) ? $interval : $BlinkBridge_DefaultInterval;
  $hash->{webCmd} = 'arm:update';
  $hash->{devStateIcon} = '.*:noIcon:noFhemwebLink';

  return 'interval must be numeric and greater than 0'
    if !looks_like_number($hash->{INTERVAL}) || $hash->{INTERVAL} <= 0;

  readingsSingleUpdate($hash, 'state', 'defined', 0);
  BlinkBridge_Schedule($hash, 1);

  return undef;
}

sub BlinkBridge_Undef {
  my ($hash, $name) = @_;
  RemoveInternalTimer($hash);
  return undef;
}

sub BlinkBridge_Delete {
  my ($hash, $name) = @_;
  RemoveInternalTimer($hash);
  return undef;
}

sub BlinkBridge_Attr {
  my ($cmd, $name, $attrName, $attrValue) = @_;
  my $hash = $defs{$name};
  return undef if !$hash;

  if ($cmd eq 'set' && ($attrName eq 'interval' || $attrName eq 'timeout')) {
    return "$attrName must be numeric and greater than 0"
      if !defined($attrValue) || !looks_like_number($attrValue) || $attrValue <= 0;
  }

  if ($attrName eq 'disable' || $attrName eq 'disabledForIntervals' || $attrName eq 'interval') {
    RemoveInternalTimer($hash);
    if ($cmd eq 'set' && $attrName eq 'disable' && $attrValue) {
      readingsSingleUpdate($hash, 'state', 'disabled', 1) if $init_done;
      return undef;
    }
    BlinkBridge_Schedule($hash, 1) if $init_done;
  }

  return undef;
}

sub BlinkBridge_Set {
  my ($hash, @a) = @_;
  return 'no set argument specified' if @a < 2;

  my ($name, $cmd, @args) = @a;
  my $choices = BlinkBridge_Choices();
  return "Unknown argument $cmd, choose one of $choices"
    if $cmd eq '?' || $cmd !~ m/^(update|arm|thumbnail|snapshot)$/;

  return 'device is disabled' if IsDisabled($name);

  if ($cmd eq 'update') {
    return 'set update does not take an argument' if @args;
    BlinkBridge_RequestState($hash, 'manual', 0);
    return undef;
  }

  if ($cmd eq 'arm') {
    return 'set arm needs on or off' if @args != 1;
    my $value = BlinkBridge_NormalizeBool($args[0]);
    return 'set arm value must be on or off' if !defined($value);
    readingsSingleUpdate($hash, 'last_command', "arm $value", 1);
    BlinkBridge_SendSet($hash, "arm=$value");
    return undef;
  }

  return "set $cmd needs a camera name or id" if @args != 1;
  readingsSingleUpdate($hash, 'last_command', "$cmd $args[0]", 1);
  BlinkBridge_RequestImage($hash, $cmd, $args[0]);
  return undef;
}

sub BlinkBridge_Get {
  my ($hash, @a) = @_;
  return 'no get argument specified' if @a < 2;

  my ($name, $cmd, @args) = @a;
  my $choices = 'update:noArg state:noArg thumbnail:textField snapshot:textField';
  return "Unknown argument $cmd, choose one of $choices"
    if $cmd eq '?' || $cmd !~ m/^(update|state|thumbnail|snapshot)$/;

  return ReadingsVal($name, 'state', 'unknown') if $cmd eq 'state';
  return 'device is disabled' if IsDisabled($name);

  if ($cmd eq 'update') {
    return 'get update does not take an argument' if @args;
    BlinkBridge_RequestState($hash, 'manual', 0);
    return 'update request sent';
  }

  return "get $cmd needs a camera name or id" if @args != 1;
  BlinkBridge_RequestImage($hash, $cmd, $args[0]);
  return "$cmd request sent for $args[0]";
}

sub BlinkBridge_Choices {
  return 'update:noArg arm:on,off thumbnail:textField snapshot:textField';
}

sub BlinkBridge_NormalizeBool {
  my ($value) = @_;
  return undef if !defined($value);
  my $normalized = lc($value);
  return 'on' if $normalized =~ m/^(1|true|yes|y|on|ein|armed|arm)$/;
  return 'off' if $normalized =~ m/^(0|false|no|n|off|aus|disarmed|disarm)$/;
  return undef;
}

sub BlinkBridge_Schedule {
  my ($hash, $delay) = @_;
  my $name = $hash->{NAME};
  return if !$name || IsDisabled($name);

  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday() + $delay, \&BlinkBridge_Timer, $hash, 0);
  return undef;
}

sub BlinkBridge_Timer {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if (IsDisabled($name)) {
    readingsSingleUpdate($hash, 'state', 'disabled', 1);
    return undef;
  }

  BlinkBridge_RequestState($hash, 'timer', 1);
  return undef;
}

sub BlinkBridge_RequestState {
  my ($hash, $reason, $scheduleNext) = @_;
  my $name = $hash->{NAME};

  if ($hash->{helper}{REQUEST_RUNNING}) {
    BlinkBridge_Schedule($hash, BlinkBridge_Interval($hash)) if $scheduleNext;
    return undef;
  }

  $hash->{helper}{REQUEST_RUNNING} = 1;
  my $param = {
    url          => $hash->{BASE_URL} . '/state',
    timeout      => BlinkBridge_Timeout($hash),
    method       => 'GET',
    keepalive    => 1,
    name         => $name,
    reason       => $reason,
    scheduleNext => $scheduleNext,
    callback     => \&BlinkBridge_Response,
  };

  HttpUtils_NonblockingGet($param);
  return undef;
}

sub BlinkBridge_SendSet {
  my ($hash, $query) = @_;
  my $name = $hash->{NAME};
  my $param = {
    url          => $hash->{BASE_URL} . '/set?' . $query,
    timeout      => BlinkBridge_Timeout($hash),
    method       => 'GET',
    keepalive    => 1,
    name         => $name,
    reason       => 'set',
    scheduleNext => 0,
    callback     => \&BlinkBridge_Response,
  };

  HttpUtils_NonblockingGet($param);
  return undef;
}

sub BlinkBridge_RequestImage {
  my ($hash, $mode, $camera) = @_;
  my $name = $hash->{NAME};
  my $safeDevice = BlinkBridge_SafeName($name);
  my $safeCamera = BlinkBridge_SafeName($camera);
  my $filename = "BlinkBridge_${safeDevice}_${mode}_${safeCamera}.jpg";
  my $path = BlinkBridge_ImagePath($hash) . '/' . $filename;
  my $url = $hash->{BASE_URL} . '/' . $mode . '?camera=' . BlinkBridge_UrlEncode($camera);

  my $param = {
    url              => $url,
    timeout          => BlinkBridge_Timeout($hash) + 90,
    method           => 'GET',
    keepalive        => 1,
    name             => $name,
    reason           => 'image',
    imageMode        => $mode,
    imageCamera      => $camera,
    imageSafeCamera  => $safeCamera,
    imageFile        => $path,
    imageAttachment  => $filename,
    callback         => \&BlinkBridge_ImageResponse,
  };

  HttpUtils_NonblockingGet($param);
  return undef;
}

sub BlinkBridge_Response {
  my ($param, $err, $data) = @_;
  my $name = $param->{name};
  my $hash = $defs{$name};
  return undef if !$hash;

  $hash->{helper}{REQUEST_RUNNING} = 0 if $param->{reason} ne 'set';

  if ($err) {
    BlinkBridge_UpdateError($hash, $err);
    BlinkBridge_Schedule($hash, BlinkBridge_Interval($hash)) if $param->{scheduleNext};
    return undef;
  }

  if (!defined($data) || $data eq '') {
    BlinkBridge_UpdateError($hash, 'empty bridge response');
    BlinkBridge_Schedule($hash, BlinkBridge_Interval($hash)) if $param->{scheduleNext};
    return undef;
  }

  my $json = eval { JSON::PP::decode_json($data) };
  if ($@ || ref($json) ne 'HASH') {
    BlinkBridge_UpdateError($hash, 'invalid JSON bridge response');
    BlinkBridge_Schedule($hash, BlinkBridge_Interval($hash)) if $param->{scheduleNext};
    return undef;
  }

  BlinkBridge_UpdateReadings($hash, $json);
  BlinkBridge_Schedule($hash, BlinkBridge_Interval($hash)) if $param->{scheduleNext};
  return undef;
}

sub BlinkBridge_ImageResponse {
  my ($param, $err, $data) = @_;
  my $name = $param->{name};
  my $hash = $defs{$name};
  return undef if !$hash;

  if ($err) {
    BlinkBridge_UpdateError($hash, $err);
    return undef;
  }

  if (!defined($data) || $data eq '') {
    BlinkBridge_UpdateError($hash, 'empty image response');
    return undef;
  }

  my $path = $param->{imageFile};
  my $fh;
  if (!open($fh, '>', $path)) {
    BlinkBridge_UpdateError($hash, "cannot write image file $path: $!");
    return undef;
  }
  binmode($fh);
  print {$fh} $data;
  close($fh);

  my $safeCamera = $param->{imageSafeCamera};
  my $imageUpdated = sprintf('%.3f', scalar(gettimeofday()));
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, 'last_image_updated', $imageUpdated);
  readingsBulkUpdate($hash, 'last_image_mode', $param->{imageMode});
  readingsBulkUpdate($hash, 'last_image_camera', $param->{imageCamera});
  readingsBulkUpdate($hash, 'last_image_file', $path);
  readingsBulkUpdate($hash, 'last_image_attachment', $param->{imageAttachment});
  readingsBulkUpdate($hash, "camera_${safeCamera}_updated", $imageUpdated);
  readingsBulkUpdate($hash, "camera_${safeCamera}_file", $path);
  readingsBulkUpdate($hash, "camera_${safeCamera}_attachment", $param->{imageAttachment});
  readingsBulkUpdateIfChanged($hash, 'last_error', 'none');
  readingsEndUpdate($hash, 1);

  return undef;
}

sub BlinkBridge_UpdateReadings {
  my ($hash, $data) = @_;
  my $stateText = BlinkBridge_StateText($data);

  $hash->{VERSION} = $BlinkBridge_Version;

  readingsBeginUpdate($hash);
  for my $key (sort keys %{$data}) {
    next if $key =~ m/^(networks|cameras|command)$/;
    readingsBulkUpdateIfChanged($hash, $key, BlinkBridge_ReadingValue($data->{$key}));
  }

  BlinkBridge_UpdateNetworkReadings($hash, $data->{networks});
  BlinkBridge_UpdateCameraReadings($hash, $data->{cameras});

  readingsBulkUpdateIfChanged($hash, 'last_error', 'none');
  readingsBulkUpdateIfChanged($hash, 'state', $stateText);
  readingsEndUpdate($hash, 1);

  return undef;
}

sub BlinkBridge_UpdateNetworkReadings {
  my ($hash, $networks) = @_;
  return undef if ref($networks) ne 'HASH';

  my @names = sort keys %{$networks};
  readingsBulkUpdateIfChanged($hash, 'networkList', join(',', @names));
  for my $network (@names) {
    my $safe = BlinkBridge_SafeName($network);
    my $values = $networks->{$network};
    next if ref($values) ne 'HASH';
    for my $key (sort keys %{$values}) {
      readingsBulkUpdateIfChanged($hash, "network_${safe}_${key}", BlinkBridge_ReadingValue($values->{$key}));
    }
  }
  return undef;
}

sub BlinkBridge_UpdateCameraReadings {
  my ($hash, $cameras) = @_;
  return undef if ref($cameras) ne 'HASH';

  my @names = sort keys %{$cameras};
  readingsBulkUpdateIfChanged($hash, 'cameraList', join(',', @names));
  for my $camera (@names) {
    my $safe = BlinkBridge_SafeName($camera);
    my $values = $cameras->{$camera};
    next if ref($values) ne 'HASH';
    for my $key (sort keys %{$values}) {
      readingsBulkUpdateIfChanged($hash, "camera_${safe}_${key}", BlinkBridge_ReadingValue($values->{$key}));
    }
  }
  return undef;
}

sub BlinkBridge_UpdateError {
  my ($hash, $message) = @_;
  my $name = $hash->{NAME};

  Log3($name, 3, "BlinkBridge ($name) $message");
  readingsBeginUpdate($hash);
  readingsBulkUpdateIfChanged($hash, 'availability', 'offline');
  readingsBulkUpdateIfChanged($hash, 'last_error', $message);
  readingsBulkUpdateIfChanged($hash, 'state', 'error');
  readingsEndUpdate($hash, 1);

  return undef;
}

sub BlinkBridge_StateText {
  my ($data) = @_;
  my $availability = $data->{availability} // 'unknown';
  return $availability if $availability ne 'online';

  my $networks = $data->{networks};
  my @armed;
  my @disarmed;
  if (ref($networks) eq 'HASH') {
    for my $network (sort keys %{$networks}) {
      if ($networks->{$network}{armed}) {
        push @armed, $network;
      } else {
        push @disarmed, $network;
      }
    }
  }

  my $cameraCount = 0;
  $cameraCount = scalar keys %{$data->{cameras}} if ref($data->{cameras}) eq 'HASH';
  my $alarm = @armed ? 'armed' : 'disarmed';
  my $networkText = @armed ? join(',', @armed) : join(',', @disarmed);
  return "$alarm | $networkText | $cameraCount cameras";
}

sub BlinkBridge_ReadingValue {
  my ($value) = @_;
  return 'null' if !defined($value);
  return $value ? 1 : 0 if ref($value) eq 'JSON::PP::Boolean';
  return JSON::PP::encode_json($value) if ref($value) eq 'HASH' || ref($value) eq 'ARRAY';
  return $value;
}

sub BlinkBridge_Interval {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return AttrVal($name, 'interval', $hash->{INTERVAL} || $BlinkBridge_DefaultInterval);
}

sub BlinkBridge_Timeout {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return AttrVal($name, 'timeout', 15);
}

sub BlinkBridge_ImagePath {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $path = AttrVal($name, 'imagePath', $BlinkBridge_DefaultImagePath);
  $path =~ s{/+$}{};
  return $path || $BlinkBridge_DefaultImagePath;
}

sub BlinkBridge_UrlEncode {
  my ($value) = @_;
  $value = '' if !defined($value);
  $value =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/eg;
  return $value;
}

sub BlinkBridge_SafeName {
  my ($value) = @_;
  $value = '' if !defined($value);
  $value =~ s/[^A-Za-z0-9_.-]+/_/g;
  $value =~ s/^\.+|\.+$//g;
  $value =~ s/^_+|_+$//g;
  return $value || 'unknown';
}

1;

=pod
=item device
=item summary    Blink cameras through a local blinkpy bridge
=item summary_DE Blink Kameras ueber eine lokale blinkpy Bridge
=begin html

<a id="BlinkBridge"></a>
<h3>BlinkBridge</h3>
<ul>
  Controls Blink cameras through the local FHEM-BlinkBridge HTTP bridge. The
  module keeps Python and Blink OAuth outside the FHEM container.
  <br><br>

  <a id="BlinkBridge-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; BlinkBridge &lt;bridgeUrl&gt; [interval]</code>
  </ul>
  <br>

  <a id="BlinkBridge-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; arm on|off</code><br>
      Arms or disarms the first Blink network.</li>
    <li><code>set &lt;name&gt; thumbnail &lt;camera&gt;</code><br>
      Downloads the current thumbnail into <code>imagePath</code>.</li>
    <li><code>set &lt;name&gt; snapshot &lt;camera&gt;</code><br>
      Requests a fresh Blink picture and downloads it into <code>imagePath</code>.</li>
    <li><code>set &lt;name&gt; update</code><br>
      Requests a state refresh.</li>
  </ul>
  <br>

  <a id="BlinkBridge-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>availability</code>: bridge status, for example <code>online</code>,
      <code>offline</code> or <code>auth_required</code>.</li>
    <li><code>networkList</code>, <code>cameraList</code>: comma separated names.</li>
    <li><code>network_..._armed</code>, <code>network_..._online</code>: network state.</li>
    <li><code>camera_..._motion_enabled</code>, <code>camera_..._battery</code>,
      <code>camera_..._temperature_c</code>: camera details.</li>
    <li><code>last_image_file</code>, <code>last_image_attachment</code>: last downloaded image.</li>
  </ul>
  <br>

  <a id="BlinkBridge-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>interval</code>: poll interval in seconds. Default: 60.</li>
    <li><code>timeout</code>: HTTP timeout in seconds. Default: 15.</li>
    <li><code>imagePath</code>: target directory for downloaded images. Default: <code>/tmp</code>.</li>
    <li><code>disable</code>, <code>disabledForIntervals</code>.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
</ul>

=end html

=begin html_DE

<a id="BlinkBridge"></a>
<h3>BlinkBridge</h3>
<ul>
  Steuert Blink Kameras ueber die lokale FHEM-BlinkBridge HTTP-Bridge. Python
  und Blink OAuth bleiben ausserhalb des FHEM-Containers.
  <br><br>

  <a id="BlinkBridge-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; BlinkBridge &lt;bridgeUrl&gt; [interval]</code>
  </ul>
  <br>

  <a id="BlinkBridge-set"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; arm on|off</code><br>
      Schaltet das erste Blink Netzwerk scharf oder unscharf.</li>
    <li><code>set &lt;name&gt; thumbnail &lt;camera&gt;</code><br>
      Laedt das aktuelle Vorschaubild nach <code>imagePath</code>.</li>
    <li><code>set &lt;name&gt; snapshot &lt;camera&gt;</code><br>
      Fordert ein frisches Blink Bild an und laedt es nach <code>imagePath</code>.</li>
    <li><code>set &lt;name&gt; update</code><br>
      Fordert sofort einen Status an.</li>
  </ul>
  <br>

  <a id="BlinkBridge-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>availability</code>: Bridge-Status, z.B. <code>online</code>,
      <code>offline</code> oder <code>auth_required</code>.</li>
    <li><code>networkList</code>, <code>cameraList</code>: Namen als kommagetrennte Liste.</li>
    <li><code>network_..._armed</code>, <code>network_..._online</code>: Netzwerkstatus.</li>
    <li><code>camera_..._motion_enabled</code>, <code>camera_..._battery</code>,
      <code>camera_..._temperature_c</code>: Kameradetails.</li>
    <li><code>last_image_file</code>, <code>last_image_attachment</code>: zuletzt geladenes Bild.</li>
  </ul>
  <br>

  <a id="BlinkBridge-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><code>interval</code>: Poll-Intervall in Sekunden. Default: 60.</li>
    <li><code>timeout</code>: HTTP-Timeout in Sekunden. Default: 15.</li>
    <li><code>imagePath</code>: Zielverzeichnis fuer heruntergeladene Bilder. Default: <code>/tmp</code>.</li>
    <li><code>disable</code>, <code>disabledForIntervals</code>.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
</ul>

=end html_DE

=cut
