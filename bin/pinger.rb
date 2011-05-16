#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'

require 'redis'

$LOAD_PATH << File.dirname(__FILE__) + '/..'
require 'lib/app.rb'

class Pinger
  # Interval between pings; if changed, adjust KEEP.
  INTERVAL = 1
  # Pings will be considered lost if they take more than half a second.
  TIMEOUT = 0.5
  # We show 15sec, 1min, 5min + trend.
  # So we need at least 10 mins of data.
  KEEP_COUNT = 600

  def self.ping(nic)
    puts "Pinger starting."
    pinger = Pinger.new(nic)
    puts "Pinger ready."
    pinger.ping
  end

  def initialize(nic)
    @nic = nic

    @redis = Redis.new
    @redis_key = "ping-#{nic}"

    @last_seq = 0
    @last_status = Time.now.min
  end

  def ping
    ppp = Potato::PPP.new
    until iface = ppp.find_by_nic(@nic)
      puts "Interface #{@nic} not attached yet."
      sleep(30)
    end

    if old_lost = @redis.lindex(@redis_key, 0)
      puts "Resuming old ping with #{old_lost} lost packets."
    end
    @lost = old_lost.to_i

    target = iface.ip_remote
    device = iface.device

    launch_ping(target, device)
    launch_timeout

    receive_pings
  ensure
    Process.kill('TERM', @ping_pid) if @ping_pid
  end

  private

  def launch_ping(target, device)
    puts "Pinging #{target} on #{device}."

    args = [
      '-i', INTERVAL,
      '-t', 0,
      '-r',
      '-I', device,
      target
    ]

    @ping_fh, ping_writer = IO.pipe
    @ping_pid = fork do
      $stdout.reopen(ping_writer)
      $stdin.close

      exec('ping', *args.map(&:to_s))
    end
  end

  def launch_timeout
    @expected = {1 => Time.now + INTERVAL + TIMEOUT}

    Thread.abort_on_exception = true
    Thread.new do
      loop do
        now = Time.now
        @expected.dup.each do |seq, time|
          ping_result(seq, :timeout) if time < now
        end

        if next_timeout = @expected.values.min
          sleep(next_timeout - Time.now)
        else
          sleep(INTERVAL)
        end
      end
    end
  end

  def ping_result(seq, result)
    timeout = TIMEOUT

    case result
    when :timeout
      @lost += 1
      timeout = 0
      puts "Ping #{seq} timed out."
    when :response
      if seq < @last_seq
        if !@expected.has_key?(seq)
          puts "Ping #{seq} received too late."
        else
          puts "Ping #{seq} received out of order."
        end
      end
    else
      raise "Unknown ping result: #{result}"
    end

    @redis.lpush(@redis_key, @lost)
    @redis.ltrim(@redis_key, 0, KEEP_COUNT - 1)

    output_status

    @expected.delete(seq)
    if seq >= @last_seq
      @expected[seq + 1] = Time.now + INTERVAL + timeout
      @last_seq = seq
    end
  end

  def output_status
    return if Time.now.min == @last_status

    if prior = @redis.lindex(@redis_key, 59)
      diff = @lost - prior.to_i
      percent = sprintf('%.2f', diff / 0.6)
      puts "Current loss: #{prior} -> #{@lost} = #{percent}%"
    end

    @last_status = Time.now.min
  end

  def receive_pings
    @ping_fh.each_line do |line|
      next unless line =~ / icmp_req=(\d+) /
      ping_result($1.to_i, :response)
    end
  end
end

Pinger.ping(*ARGV)