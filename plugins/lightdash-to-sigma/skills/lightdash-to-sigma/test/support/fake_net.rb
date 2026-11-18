# frozen_string_literal: true
# TEST-ONLY. Preloaded into the orchestrator's child ruby processes (RUBYOPT=-r<this file>) so the real scripts run
# end to end with NO network: Net::HTTP#start / #request are replaced by an in-memory fake of the few Sigma and
# Lightdash endpoints the migration calls. State lives in FAKE_STATE_DIR (shared by every child process and by the
# test), every call is appended to FAKE_STATE_DIR/calls.jsonl as {method, path, body}.
#
#   Sigma     GET /v2/dataModels, GET|PUT /v2/dataModels/{id}/spec, POST /v2/dataModels/spec,
#             POST /v2/workbooks (dryRun honoured; FAKE_DRYRUN_ERROR=<msg> makes the dry run answer 400),
#             GET /v2/workbooks/{id}
#   Lightdash GET /api/v1/projects/*/{dashboards,charts}/code, /explores/{id}   (served from FAKE_FIXTURE)
#   anything else -> 404
#
# Not a Sigma/Lightdash simulator: it only stores what is POSTed and echoes it back.

require 'net/http'
require 'json'
require 'yaml'
require 'date'
require 'fileutils'

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

  def yaml(path)
    YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [Date, Time], aliases: true)
  end

  def handle(req)
    path = req.path.to_s
    body = req.body.to_s
    File.open(File.join(DIR, 'calls.jsonl'), 'a') { |f| f.puts(JSON.generate('method' => req.method, 'path' => path, 'body' => body)) }
    return lightdash(req, path) if path.start_with?('/api/v1/')
    sigma(req, path, body)
  end

  def lightdash(_req, path)
    fx = File.join(ENV['FAKE_FIXTURE'].to_s, 'lightdash')
    case path
    when %r{/dashboards/code\z}
      respond(200, 'status' => 'ok', 'results' => { 'dashboards' => Dir.glob(File.join(fx, 'dashboards', '*.yml')).sort.map { |f| yaml(f) } })
    when %r{/charts/code\z}
      respond(200, 'status' => 'ok', 'results' => { 'charts' => Dir.glob(File.join(fx, 'charts', '*.yml')).sort.map { |f| yaml(f) } })
    when %r{/explores/([^/]+)\z}
      f = File.join(ENV['FAKE_FIXTURE'].to_s, 'explores', "#{Regexp.last_match(1)}.json")
      File.file?(f) ? respond(200, 'status' => 'ok', 'results' => JSON.parse(File.read(f, encoding: 'UTF-8'))['results']) : respond(404, 'status' => 'error')
    else respond(404, 'status' => 'error', 'error' => { 'name' => 'NotFound' })
    end
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
      doc = JSON.parse(body)
      if doc['dryRun']
        return respond(400, 'valid' => false, 'errors' => [{ 'summary' => ENV['FAKE_DRYRUN_ERROR'] }]) unless ENV['FAKE_DRYRUN_ERROR'].to_s.empty?
        return respond(200, {})
      end
      write('workbook.json', doc)
      respond(200, 'workbookId' => 'wb-1')
    when ['GET', '/v2/workbooks/wb-1']
      respond(200, 'workbookId' => 'wb-1', 'contents' => (read('workbook.json', {})['contents'] || {}))
    else
      m = path.match(%r{\A/v2/dataModels/([^/]+)/spec\z})
      dm = m && dms.find { |d| d['id'] == m[1] }
      if m && dm && req.method == 'GET'
        spec = dm['spec']
        if ENV['FAKE_DROP_COLUMN'] == '1' # a server that silently drops a column
          spec = JSON.parse(JSON.generate(spec))
          spec['pages'][0]['elements'][0]['columns'].pop
        end
        respond(200, spec)
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
