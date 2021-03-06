# -*- encoding: binary -*-
require 'test/setup'
require 'stringio'
require 'tempfile'
require 'fileutils'

class TestMogileFS__MogileFS < TestMogileFS
  include MogileFS::Util

  def setup
    @klass = MogileFS::MogileFS
    super
  end

  def test_initialize
    assert_equal 'test', @client.domain

    assert_raises ArgumentError do
      MogileFS::MogileFS.new :hosts => ['kaa:6001']
    end
  end

  def test_get_file_data_http
    tmp = Tempfile.new('accept')
    accept = File.open(tmp.path, "ab")
    svr = Proc.new do |serv, port|
      client, client_addr = serv.accept
      client.sync = true
      readed = client.recv(4096, 0)
      assert(readed =~ \
            %r{\AGET /dev[12]/0/000/000/0000000062\.fid HTTP/1.[01]\r\n\r\n\Z})
      accept.syswrite('.')
      client.send("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\ndata!", 0)
      client.close
    end
    t1 = TempServer.new(svr)
    t2 = TempServer.new(svr)
    path1 = "http://127.0.0.1:#{t1.port}/dev1/0/000/000/0000000062.fid"
    path2 = "http://127.0.0.1:#{t2.port}/dev2/0/000/000/0000000062.fid"

    @backend.get_paths = { 'paths' => 2, 'path1' => path1, 'path2' => path2 }

    assert_equal 'data!', @client.get_file_data('key')
    assert_equal 1, accept.stat.size
    ensure
      TempServer.destroy_all!
  end

  def test_get_file_data_http_not_found_failover
    tmp = Tempfile.new('accept')
    accept = File.open(tmp.path, 'ab')
    svr1 = Proc.new do |serv, port|
      client, client_addr = serv.accept
      client.sync = true
      readed = client.recv(4096, 0)
      assert(readed =~ \
            %r{\AGET /dev1/0/000/000/0000000062\.fid HTTP/1.[01]\r\n\r\n\Z})
      accept.syswrite('.')
      client.send("HTTP/1.0 404 Not Found\r\n\r\ndata!", 0)
      client.close
    end

    svr2 = Proc.new do |serv, port|
      client, client_addr = serv.accept
      client.sync = true
      readed = client.recv(4096, 0)
      assert(readed =~ \
            %r{\AGET /dev2/0/000/000/0000000062\.fid HTTP/1.[01]\r\n\r\n\Z})
      accept.syswrite('.')
      client.send("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\ndata!", 0)
      client.close
    end

    t1 = TempServer.new(svr1)
    t2 = TempServer.new(svr2)
    path1 = "http://127.0.0.1:#{t1.port}/dev1/0/000/000/0000000062.fid"
    path2 = "http://127.0.0.1:#{t2.port}/dev2/0/000/000/0000000062.fid"
    @backend.get_paths = { 'paths' => 2, 'path1' => path1, 'path2' => path2 }

    assert_equal 'data!', @client.get_file_data('key')
    assert_equal 2, accept.stat.size
    ensure
      TempServer.destroy_all!
  end

  def test_get_file_data_http_block
    tmpfp = Tempfile.new('test_mogilefs.open_data')
    nr = nr_chunks
    chunk_size = 1024 * 1024
    expect_size = nr * chunk_size
    header = "HTTP/1.0 200 OK\r\n" \
             "Content-Length: #{expect_size}\r\n\r\n"
    assert_equal header.size, tmpfp.syswrite(header)
    nr.times { assert_equal chunk_size, tmpfp.syswrite(' ' * chunk_size) }
    assert_equal expect_size + header.size, File.size(tmpfp.path)
    tmpfp.sysseek(0)

    accept = Tempfile.new('accept')
    svr = Proc.new do |serv, port|
      client, client_addr = serv.accept
      client.sync = true
      accept.syswrite('.')
      readed = client.recv(4096, 0)
      assert(readed =~ \
            %r{\AGET /dev[12]/0/000/000/0000000062\.fid HTTP/1.[01]\r\n\r\n\Z})
      sysrwloop(tmpfp, client)
      client.close
      exit 0
    end
    t1 = TempServer.new(svr)
    t2 = TempServer.new(svr)
    path1 = "http://127.0.0.1:#{t1.port}/dev1/0/000/000/0000000062.fid"
    path2 = "http://127.0.0.1:#{t2.port}/dev2/0/000/000/0000000062.fid"

    @backend.get_paths = { 'paths' => 2, 'path1' => path1, 'path2' => path2 }

    data = Tempfile.new('test_mogilefs.dest_data')
    read_nr = nr = 0
    @client.get_file_data('key') do |fp|
      buf = ''
      loop do
        begin
          fp.sysread(16384, buf)
          read_nr = buf.size
          nr += read_nr
          assert_equal read_nr, data.syswrite(buf), "partial write"
        rescue Errno::EAGAIN
          retry
        rescue EOFError
          break
        end
      end
    end
    assert_equal expect_size, nr, "size mismatch"
    assert_equal 1, accept.stat.size
  end

  def test_get_paths
    path1 = 'http://rur-1/dev1/0/000/000/0000000062.fid'
    path2 = 'http://rur-2/dev2/0/000/000/0000000062.fid'

    @backend.get_paths = { 'paths' => 2, 'path1' => path1, 'path2' => path2 }

    expected = [ path1, path2 ]

    assert_equal expected, @client.get_paths('key').sort
  end

  def test_get_uris
    path1 = 'http://rur-1/dev1/0/000/000/0000000062.fid'
    path2 = 'http://rur-2/dev2/0/000/000/0000000062.fid'

    @backend.get_paths = { 'paths' => 2, 'path1' => path1, 'path2' => path2 }

    expected = [ URI.parse(path1), URI.parse(path2) ]

    assert_equal expected, @client.get_uris('key')
  end


  def test_get_paths_unknown_key
    @backend.get_paths = ['unknown_key', '']

    assert_raises MogileFS::Backend::UnknownKeyError do
      assert_equal nil, @client.get_paths('key')
    end
  end

  def test_delete_existing
    @backend.delete = { }
    assert_nothing_raised do
      @client.delete 'no_such_key'
    end
  end

  def test_delete_nonexisting
    @backend.delete = 'unknown_key', ''
    assert_raises MogileFS::Backend::UnknownKeyError do
      @client.delete('no_such_key')
    end
  end

  def test_delete_readonly
    @client.readonly = true
    assert_raises MogileFS::ReadOnlyError do
      @client.delete 'no_such_key'
    end
  end

  def test_each_key
    @backend.list_keys = { 'key_count' => 2, 'next_after' => 'new_key_2',
                           'key_1' => 'new_key_1', 'key_2' => 'new_key_2' }
    @backend.list_keys = { 'key_count' => 2, 'next_after' => 'new_key_4',
                           'key_1' => 'new_key_3', 'key_2' => 'new_key_4' }
    @backend.list_keys = { 'key_count' => 0, 'next_after' => 'new_key_4' }
    keys = []
    @client.each_key 'new' do |key|
      keys << key
    end

    assert_equal %w[new_key_1 new_key_2 new_key_3 new_key_4], keys
  end

  def test_list_keys
    @backend.list_keys = { 'key_count' => '2', 'next_after' => 'new_key_2',
                           'key_1' => 'new_key_1', 'key_2' => 'new_key_2' }

    keys, next_after = @client.list_keys 'new'
    assert_equal ['new_key_1', 'new_key_2'], keys.sort
    assert_equal 'new_key_2', next_after
  end

  def test_list_keys_block
    @backend.list_keys = { 'key_count' => '2', 'next_after' => 'new_key_2',
                           'key_1' => 'new_key_1', 'key_2' => 'new_key_2' }
    http_resp = "HTTP/1.0 200 OK\r\nContent-Length: %u\r\n"
    srv = Proc.new do |serv, port, size|
      client, client_addr = serv.accept
      client.sync = true
      readed = client.readpartial(4096)
      assert %r{\AHEAD } =~ readed
      client.send(http_resp % size, 0)
      client.close
    end
    t1 = TempServer.new(Proc.new { |serv, port| srv.call(serv, port, 5) })
    t2 = TempServer.new(Proc.new { |serv, port| srv.call(serv, port, 5) })
    t3 = TempServer.new(Proc.new { |serv, port| srv.call(serv, port, 10) })
    @backend.get_paths = { 'paths' => '2',
                           'path1' => "http://127.0.0.1:#{t1.port}/",
                           'path2' => "http://127.0.0.1:#{t2.port}/" }
    @backend.get_paths = { 'paths' => '1',
                           'path1' => "http://127.0.0.1:#{t3.port}/" }

    res = []
    keys, next_after = @client.list_keys('new') do |key,length,devcount|
      res << [ key, length, devcount ]
    end

    expect_res = [ [ 'new_key_1', 5, 2 ], [ 'new_key_2', 10, 1 ] ]
    assert_equal expect_res, res
    assert_equal ['new_key_1', 'new_key_2'], keys.sort
    assert_equal 'new_key_2', next_after
    ensure
      TempServer.destroy_all!
  end

  def test_new_file_http
    @client.readonly = true
    assert_raises MogileFS::ReadOnlyError do
      @client.new_file 'new_key', 'test'
    end
  end

  def test_new_file_readonly
    @client.readonly = true
    assert_raises MogileFS::ReadOnlyError do
      @client.new_file 'new_key', 'test'
    end
  end

  def test_size_http
    accept = Tempfile.new('accept')
    t = TempServer.new(Proc.new do |serv,port|
      client, client_addr = serv.accept
      client.sync = true
      readed = client.recv(4096, 0) rescue nil
      accept.syswrite('.')
      assert_equal "HEAD /path HTTP/1.0\r\n\r\n", readed
      client.send("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\n", 0)
      client.close
    end)

    path = "http://127.0.0.1:#{t.port}/path"
    @backend.get_paths = { 'paths' => 1, 'path1' => path }

    assert_equal 5, @client.size('key')
    assert_equal 1, accept.stat.size
  end

  def test_bad_size_http
    tmp = Tempfile.new('accept')
    t = TempServer.new(Proc.new do |serv,port|
      client, client_addr = serv.accept
      client.sync = true
      readed = client.recv(4096, 0) rescue nil
      assert_equal "HEAD /path HTTP/1.0\r\n\r\n", readed
      tmp.syswrite('.')
      client.send("HTTP/1.0 404 Not Found\r\nContent-Length: 5\r\n\r\n", 0)
      client.close
    end)

    path = "http://127.0.0.1:#{t.port}/path"
    @backend.get_paths = { 'paths' => 1, 'path1' => path }

    assert_nil @client.size('key')
    assert_equal 1, tmp.stat.size
  end

  def test_store_file_small_http
    received = Tempfile.new('received')
    to_store = Tempfile.new('small')
    to_store.syswrite('data')

    expected = "PUT /path HTTP/1.0\r\nContent-Length: 4\r\n\r\ndata"
    t = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      received.syswrite(client.recv(4096, 0))
      client.send("HTTP/1.0 200 OK\r\n\r\n", 0)
      client.close
    end)

    @backend.create_open = {
      'devid' => '1',
      'path' => "http://127.0.0.1:#{t.port}/path",
    }
    nr = @client.store_file 'new_key', 'test', to_store.path
    assert_equal 4, nr
    received.sysseek(0)
    assert_equal expected, received.sysread(4096)
    ensure
      TempServer.destroy_all!
  end

  def test_store_content_http
    received = Tempfile.new('recieved')
    expected = "PUT /path HTTP/1.0\r\nContent-Length: 4\r\n\r\ndata"

    t = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      received.syswrite(client.recv(4096, 0))
      client.send("HTTP/1.0 200 OK\r\n\r\n", 0)
      client.close
    end)

    @backend.create_open = {
      'devid' => '1',
      'path' => "http://127.0.0.1:#{t.port}/path",
    }

    nr = @client.store_content 'new_key', 'test', 'data'
    assert nr
    assert_equal 4, nr

    received.sysseek(0)
    assert_equal expected, received.sysread(4096)
    ensure
      TempServer.destroy_all!
  end


  def test_store_content_with_writer_callback
    received = Tempfile.new('recieved')
    expected = "PUT /path HTTP/1.0\r\nContent-Length: 40\r\n\r\n"
    10.times do
      expected += "data"
    end
    t = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      nr = 0
      loop do
        buf = client.readpartial(8192) or break
        break if buf.length == 0
        assert_equal buf.length, received.syswrite(buf)
        nr += buf.length
        break if nr >= expected.size
      end
      client.send("HTTP/1.0 200 OK\r\n\r\n", 0)
      client.close
    end)

    @backend.create_open = {
      'devid' => '1',
      'path' => "http://127.0.0.1:#{t.port}/path",
    }

    cbk = MogileFS::Util::StoreContent.new(40) do |write_callback|
      10.times do
        write_callback.call("data")
      end
    end
    assert_equal 40, cbk.length
    nr = @client.store_content('new_key', 'test', cbk)
    assert_equal 40, nr

    received.sysseek(0)
    assert_equal expected, received.sysread(4096)
    ensure
      TempServer.destroy_all!
  end

  def test_store_content_multi_dest_failover
    received1 = Tempfile.new('received')
    received2 = Tempfile.new('received')
    expected = "PUT /path HTTP/1.0\r\nContent-Length: 4\r\n\r\ndata"

    t1 = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      received1.syswrite(client.recv(4096, 0))
      client.send("HTTP/1.0 500 Internal Server Error\r\n\r\n", 0)
      client.close
    end)

    t2 = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      received2.syswrite(client.recv(4096, 0))
      client.send("HTTP/1.0 200 OK\r\n\r\n", 0)
      client.close
    end)

    @backend.create_open = {
      'dev_count' => '2',
      'devid_1' => '1',
      'path_1' => "http://127.0.0.1:#{t1.port}/path",
      'devid_2' => '2',
      'path_2' => "http://127.0.0.1:#{t2.port}/path",
    }

    nr = @client.store_content 'new_key', 'test', 'data'
    assert_equal 4, nr
    received1.sysseek(0)
    received2.sysseek(0)
    assert_equal expected, received1.sysread(4096)
    assert_equal expected, received2.sysread(4096)
    ensure
      TempServer.destroy_all!
  end

  def test_store_content_http_fail
    t = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      client.recv(4096, 0)
      client.send("HTTP/1.0 500 Internal Server Error\r\n\r\n", 0)
      client.close
    end)

    @backend.create_open = {
      'devid' => '1',
      'path' => "http://127.0.0.1:#{t.port}/path",
    }

    assert_raises MogileFS::HTTPFile::BadResponseError do
      @client.store_content 'new_key', 'test', 'data'
    end
  end

  def test_store_content_http_empty
    received = Tempfile.new('received')
    expected = "PUT /path HTTP/1.0\r\nContent-Length: 0\r\n\r\n"
    t = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      received.syswrite(client.recv(4096, 0))
      client.send("HTTP/1.0 200 OK\r\n\r\n", 0)
      client.close
    end)

    @backend.create_open = {
      'devid' => '1',
      'path' => "http://127.0.0.1:#{t.port}/path",
    }

    nr = @client.store_content 'new_key', 'test', ''
    assert_equal 0, nr
    received.sysseek(0)
    assert_equal expected, received.sysread(4096)
  end

  def test_store_content_nfs
    @backend.create_open = {
      'dev_count' => '1',
      'devid_1' => '1',
      'path_1' => '/path',
    }
    assert_raises MogileFS::UnsupportedPathError do
      @client.store_content 'new_key', 'test', 'data'
    end
  end

  def test_new_file_http_large
    expect = Tempfile.new('test_mogilefs.expect')
    to_put = Tempfile.new('test_mogilefs.to_put')
    received = Tempfile.new('test_mogilefs.received')

    nr = nr_chunks
    chunk_size = 1024 * 1024
    expect_size = nr * chunk_size

    header = "PUT /path HTTP/1.0\r\n" \
             "Content-Length: #{expect_size}\r\n\r\n"
    assert_equal header.size, expect.syswrite(header)
    nr.times do
      assert_equal chunk_size, expect.syswrite(' ' * chunk_size)
      assert_equal chunk_size, to_put.syswrite(' ' * chunk_size)
    end
    assert_equal expect_size + header.size, expect.stat.size
    assert_equal expect_size, to_put.stat.size

    readed = Tempfile.new('readed')
    t = TempServer.new(Proc.new do |serv, accept|
      client, client_addr = serv.accept
      client.sync = true
      nr = 0
      loop do
        buf = client.readpartial(8192) or break
        break if buf.length == 0
        assert_equal buf.length, received.syswrite(buf)
        nr += buf.length
        break if nr >= expect.stat.size
      end
      readed.syswrite("#{nr}")
      client.send("HTTP/1.0 200 OK\r\n\r\n", 0)
      client.close
    end)

    @backend.create_open = {
      'devid' => '1',
      'path' => "http://127.0.0.1:#{t.port}/path",
    }

    orig_size = to_put.size
    nr = @client.store_file('new_key', 'test', to_put.path)
    assert nr
    assert_equal orig_size, nr
    assert_equal orig_size, to_put.size
    readed.sysseek(0)
    assert_equal expect.stat.size, readed.sysread(4096).to_i

    ENV['PATH'].split(/:/).each do |path|
      cmp_bin = "#{path}/cmp"
      File.executable?(cmp_bin) or next
      # puts "running #{cmp_bin} #{expect.path} #{received.path}"
      assert( system(cmp_bin, expect.path, received.path) )
      break
    end

    ensure
      TempServer.destroy_all!
  end

  def test_store_content_readonly
    @client.readonly = true

    assert_raises MogileFS::ReadOnlyError do
      @client.store_content 'new_key', 'test', nil
    end
  end

  def test_store_file_readonly
    @client.readonly = true
    assert_raises MogileFS::ReadOnlyError do
      @client.store_file 'new_key', 'test', nil
    end
  end

  def test_rename_existing
    @backend.rename = {}

    assert_nil @client.rename('from_key', 'to_key')
  end

  def test_rename_nonexisting
    @backend.rename = 'unknown_key', ''

    assert_raises MogileFS::Backend::UnknownKeyError do
      @client.rename('from_key', 'to_key')
    end
  end

  def test_rename_no_key
    @backend.rename = 'no_key', 'no_key'

    e = assert_raises MogileFS::Backend::NoKeyError do
      @client.rename 'new_key', 'test'
    end

    assert_equal 'no_key', e.message
  end

  def test_rename_readonly
    @client.readonly = true

    e = assert_raises MogileFS::ReadOnlyError do
      @client.rename 'new_key', 'test'
    end

    assert_equal 'readonly mogilefs', e.message
  end

  def test_sleep
    @backend.sleep = {}
    assert_nothing_raised do
      assert_equal({}, @client.sleep(2))
    end
  end

  private

    # tested with 1000, though it takes a while
    def nr_chunks
      ENV['NR_CHUNKS'] ? ENV['NR_CHUNKS'].to_i : 10
    end

end

