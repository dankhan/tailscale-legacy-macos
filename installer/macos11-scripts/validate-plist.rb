#!/usr/bin/ruby
# Validate effective launchd settings, independent of plist encoding or key order.
require 'json'

abort 'Tailscale installer: missing launchd plist' unless ARGV.length == 1
json = IO.popen(['/usr/bin/plutil', '-convert', 'json', '-o', '-', ARGV[0]], &:read)
abort 'Tailscale installer: invalid launchd plist' unless $?.success?
begin
  plist = JSON.parse(json)
rescue JSON::ParserError
  abort 'Tailscale installer: invalid launchd plist'
end

required = %w[Label ProgramArguments RunAtLoad KeepAlive StandardOutPath StandardErrorPath]
allowed = required + %w[EnvironmentVariables]
abort 'Tailscale installer: launchd plist has custom settings' unless
  plist.is_a?(Hash) && (required - plist.keys).empty? && (plist.keys - allowed).empty?

abort 'Tailscale installer: launchd job label differs' unless plist['Label'] == 'com.tailscale.tailscaled'
abort 'Tailscale installer: launchd startup settings differ' unless
  plist['RunAtLoad'] == true && plist['KeepAlive'] == true
abort 'Tailscale installer: launchd log paths differ' unless
  plist['StandardOutPath'] == '/var/log/tailscaled.log' &&
  plist['StandardErrorPath'] == '/var/log/tailscaled.log'

environment = plist['EnvironmentVariables']
abort 'Tailscale installer: launchd environment differs' unless
  environment.nil? || environment == { 'GODEBUG' => 'x509usefallbackroots=1' }

args = plist['ProgramArguments']
abort 'Tailscale installer: daemon executable differs' unless
  args.is_a?(Array) && args.all? { |arg| arg.is_a?(String) } &&
  args.first == '/usr/local/bin/tailscaled'
flags = args.drop(1).sort
common = %w[--socket=/var/run/tailscaled.socket --state=/var/lib/tailscale/tailscaled.state]
if flags == common.sort
  puts 'implicit-utun'
elsif flags == (common + %w[--tun=utun]).sort
  puts 'explicit-utun'
else
  abort 'Tailscale installer: daemon tunnel, state, socket, or other arguments differ'
end
