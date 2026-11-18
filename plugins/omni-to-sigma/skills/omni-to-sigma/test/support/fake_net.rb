# frozen_string_literal: true
# TEST-ONLY. Preloaded into the orchestrator's child ruby processes (RUBYOPT=-r<this file>) so the real scripts run
# end to end with NO network: Net::HTTP#start / #request are replaced by an in-memory fake of the few Sigma
# endpoints the migration calls. State lives in FAKE_STATE_DIR (shared by every child process and by the test);
# every call is appended to FAKE_STATE_DIR/calls.jsonl as {method, path, body}.
#
#   GET /v2/dataModels, GET|PUT /v2/dataModels/{id}/spec, POST /v2/dataModels/spec,
#   POST /v2/workbooks, GET /v2/workbooks/{id}
#   anything else -> 404
#
# Not a Sigma simulator: it only stores what is POSTed and echoes it back.

require 'net/http'
require 'json'

module FakeServices
  DIR = ENV['FAKE_STATE_DIR'].to_s
  module_function

  def read(name, default)
    f = File.join(DIR, name)
    File.file?(f) ? JSON.parse(File.read(f, encoding: 'UTF-8')) : default
  end

  def write(name, data)
    File.write(File.join(DIR, name), JSON.generate(data))
  end

  def respond(code, body)
    klass = Net::HTTPResponse::CODE_TO_OBJ[code.to_s] || Net::HTTPOK
    r = klass.new('1.1', code.to_s, 'fake')
    r.instance_variable_set(:@read, true)
    r.instance_variable_set(:@body, body.is_a?(String) ? body : JSON.generate(body))
    r
  end

  def handle(req)
    path = req.path.to_s
    body = req.body.to_s
    File.open(File.join(DIR, 'calls.jsonl'), 'a') { |f| f.puts(JSON.generate('method' => req.method, 'path' => path, 'body' => body)) }
    sigma(req, path, body)
  end

  def sigma(req, path, body)
    dms = read('dms.json', [])
    case [req.method, path.sub(/\?.*\z/, '')]
    when ['GET', '/v2/dataModels']
      respond(200, 'entries' => dms.map { |d| { 'dataModelId' => d['id'], 'name' => d['name'], 'updatedAt' => '2026-11-01T00:00:00Z' } })
    when ['POST', '/v2/dataModels/spec']
      spec = JSON.parse(body)
      id = "dm-#{dms.length + 1}"
      write('dms.json', dms + [{ 'id' => id, 'name' => spec['name'], 'spec' => spec }])
      respond(200, 'dataModelId' => id)
    when ['POST', '/v2/workbooks']
      write('workbook.json', JSON.parse(body))
      respond(200, 'workbookId' => 'wb-1')
    when ['GET', '/v2/workbooks/wb-1']
      respond(200, 'workbookId' => 'wb-1', 'contents' => (read('workbook.json', {})['contents'] || {}))
    else
      m = path.match(%r{\A/v2/dataModels/([^/]+)/spec\z})
      dm = m && dms.find { |d| d['id'] == m[1] }
      if m && dm && req.method == 'GET'
        respond(200, dm['spec'])
      elsif m && dm && req.method == 'PUT'
        dm['spec'] = JSON.parse(body)
        write('dms.json', dms)
        respond(200, {})
      else respond(404, 'message' => "fake: no route #{req.method} #{path}")
      end
    end
  end
end

class Net::HTTP
  def start
    block_given? ? yield(self) : self
  end

  def request(req, _body = nil)
    FakeServices.handle(req)
  end
end
