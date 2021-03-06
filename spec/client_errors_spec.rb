require 'spec_helper'

describe 'Client - Specification' do

  before(:each) do
    @s = NatsServerControl.new
    @s.start_server(true)
  end

  after(:each) do
    @s.kill_server
  end

  it 'should process errors from server' do
    nats = NATS::IO::Client.new
    nats.connect(allow_reconnect: false)

    mon = Monitor.new
    done = mon.new_cond

    errors = []
    nats.on_error do |e|
      errors << e
    end

    disconnects = []
    nats.on_disconnect do |e|
      disconnects << e
    end

    closes = 0
    nats.on_close do
      closes += 1
      mon.synchronize { done.signal }
    end

    # Trigger invalid subject server error which the client
    # detects so that it will disconnect
    nats.subscribe("hello.")

    # FIXME: This can fail due to timeout because
    # disconnection may have already occurred.
    nats.flush(1) rescue nil

    # Should have a connection closed at this without reconnecting.
    mon.synchronize { done.wait(3) }
    expect(errors.count).to eql(1)
    expect(errors.first).to be_a(NATS::IO::ServerError)
    expect(disconnects.count).to eql(1)
    expect(disconnects.first).to be_a(NATS::IO::ServerError)
    expect(closes).to eql(1)
    expect(nats.closed?).to eql(true)
  end

  it 'should handle unknown errors in the protocol' do
    mon = Monitor.new
    done = mon.new_cond

    nats = NATS::IO::Client.new
    nats.connect

    errors = []
    nats.on_error do |e|
      errors << e
    end

    disconnects = 0
    nats.on_disconnect do
      disconnects += 1
    end

    closes = 0
    nats.on_close do
      closes += 1
      mon.synchronize do
        done.signal
      end
    end

    # Modify state from internal parser
    parser = nats.instance_variable_get("@parser")
    parser.parse("ASDF\r\n")
    mon.synchronize do
      done.wait(1)
    end
    expect(errors.count).to eql(1)
    expect(errors.first).to be_a(NATS::IO::ServerError)
    expect(errors.first.to_s).to include("Unknown protocol")
    expect(disconnects).to eql(1)
    expect(closes).to eql(1)
    expect(nats.closed?).to eql(true)
  end

  context 'against a server which is idle' do
    before(:all) do
      # Start a fake tcp server
      @fake_nats_server = TCPServer.new 4555
      @fake_nats_server_th = Thread.new do
        loop do
          # Wait for a client to connect and linger
          @fake_nats_server.accept
        end
      end
    end

    after(:all) do
      @fake_nats_server_th.exit
      @fake_nats_server.close
    end

    it 'should fail due to timeout errors during connect' do
      msgs = []
      errors = []
      closes = 0
      reconnects = 0
      disconnects = []

      nats = NATS::IO::Client.new
      mon = Monitor.new
      done = mon.new_cond

      nats.on_error do |e|
        errors << e
      end

      nats.on_reconnect do
        reconnects += 1
      end

      nats.on_disconnect do |e|
        disconnects << e
      end

      nats.on_close do
        closes += 1
        mon.synchronize { done.signal }
      end

      expect do
      nats.connect({
        :servers => ["nats://127.0.0.1:4555"],
        :max_reconnect_attempts => 1,
        :reconnect_time_wait => 1,
        :connect_timeout => 1
      })
      end.to raise_error(NATS::IO::SocketTimeoutError)

      expect(disconnects.count).to eql(1)
      expect(reconnects).to eql(0)
      expect(closes).to eql(0)
      expect(disconnects.last).to be_a(NATS::IO::NoServersError)
      expect(nats.last_error).to be_a(NATS::IO::SocketTimeoutError)
      expect(errors.first).to be_a(NATS::IO::SocketTimeoutError)
      expect(errors.last).to be_a(NATS::IO::SocketTimeoutError)

      # Fails on the second reconnect attempt
      expect(errors.count).to eql(2)
      expect(nats.status).to eql(NATS::IO::DISCONNECTED)
    end
  end
end
