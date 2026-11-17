#!/usr/bin/env ruby
# frozen_string_literal: true
#
# drive.rb -- offline driver for the pbi-shaped-model corpus case (called by checks.sh).
#   ruby drive.rb <work-dir>
# Runs the REAL migrate-powerbi.rb --model-shape pbi (data model shaping, direct master map, builder with
# --direct-sources, validate and lint) against the sales fixture, with a stub required into the subprocess that
# replaces Net::HTTP: no network, no credentials. The key-uniqueness check and the slicer-carry sizes are replayed
# from the fixture's shape-probe-results.json. The orchestrator ends at the stubbed (refused) workbook POST, so the
# exit status is 4 by design. Then pbi-shaped-report.rb writes the map and limits. Outputs land in <work-dir>.
require 'json'
require 'open3'
require 'fileutils'
require 'rbconfig'

work = ARGV[0] or abort('usage: drive.rb <work-dir>')
case_dir = __dir__
repo = File.expand_path('../../..', case_dir)
skill = File.join(repo, 'plugins', 'powerbi-to-sigma', 'skills', 'powerbi-to-sigma')
scripts = File.join(skill, 'scripts')
fix = File.join(skill, 'fixtures', 'pbi-shaped', 'sales')
FileUtils.mkdir_p(work)

STUB = <<~'RUBY'
  require 'net/http'
  require 'json'
  class FakeSigmaConn
    def request(req)
      state = ENV.fetch('FAKE_SIGMA_STATE')
      code = '200'
      body = if req.path.start_with?('/v2/whoami') then JSON.generate('userId' => 'user-1')
             elsif req.path =~ %r{\A/v2/connections/[^/?]+\z} then JSON.generate('friendlyName' => true)
             elsif req.method == 'POST' && req.path == '/v2/dataModels/spec'
               File.write(File.join(state, 'dm.json'), req.body)
               JSON.generate('dataModelId' => 'dm-fake')
             elsif req.method == 'GET' && req.path.start_with?('/v2/dataModels/dm-fake/spec') then File.read(File.join(state, 'dm.json'))
             elsif req.method == 'POST' && req.path.start_with?('/v2/workbooks')
               code = '500'
               JSON.generate('message' => 'fake Sigma: workbook POST refused by the corpus driver')
             else '{}'
             end
      res = (code == '200' ? Net::HTTPOK.new('1.1', '200', 'OK') : Net::HTTPInternalServerError.new('1.1', code, 'error'))
      res.instance_variable_set(:@body, body)
      res.instance_variable_set(:@read, true)
      res
    end
  end
  class Net::HTTP
    def self.start(*_args, **_opts)
      conn = FakeSigmaConn.new
      block_given? ? yield(conn) : conn
    end
  end
RUBY

state = File.join(work, '.fake-state')
FileUtils.mkdir_p(state)
stub = File.join(state, 'fake_sigma_http.rb')
File.write(stub, STUB)
run_dir = File.join(work, 'run')
FileUtils.rm_rf(run_dir)
FileUtils.mkdir_p(run_dir)

# the sales report: overview/slicer pages plus the trend and rolling pages
a = JSON.parse(File.read(File.join(fix, 'signals.json')))
b = JSON.parse(File.read(File.join(fix, 'signals-trends.json')))
a['pages'] += b['pages']
File.write(File.join(run_dir, 'signals.json'), JSON.generate(a))

env = { 'RUBYOPT' => "-r#{stub}", 'FAKE_SIGMA_STATE' => state, 'HOME' => work, 'SIGMA_API_TOKEN' => 'tok',
        'SIGMA_BASE_URL' => 'https://api.sigmacomputing.com', 'SIGMA_ALLOW_INSECURE_BASE_URL' => '',
        'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil, 'SIGMA_WORKDIR' => nil,
        'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8' }
bundle = File.join(case_dir, 'out', 'retail-sales', 'report-bundle.json')
out, st = Open3.capture2e(env, RbConfig.ruby, File.join(scripts, 'migrate-powerbi.rb'),
                          '--tmsl', File.join(fix, 'model.bim'), '--pbir', bundle,
                          '--converter-out', File.join(fix, 'dm-raw.json'), '--out', run_dir, '--folder', 'f1', '--yes',
                          '--reuse-extract', '--model-shape', 'pbi', '--shape-probe-results', File.join(fix, 'shape-probe-results.json'))
File.write(File.join(work, 'orchestrator.log'), out)
unless st.exitstatus == 4 && File.exist?(File.join(run_dir, 'workbook-spec.json'))
  warn out.lines.last(30).join
  abort "drive.rb: orchestrator exit #{st.exitstatus} (expected 4 at the stubbed workbook POST) or no workbook-spec.json"
end

# the stub's refusal message proves the run reached the workbook POST (exit 4 alone could be any failure)
unless out.include?('workbook POST refused by the corpus driver')
  warn out.lines.last(30).join
  abort 'drive.rb: orchestrator log lacks the stub refusal; the workbook POST step was not reached'
end

# reports land in the run dir, like the orchestrator: pbi-shaped-report.rb reads model-scope.json,
# control-scope.json and coverage.json from its --out-dir
rep_dir = run_dir
args = ['--tmsl', File.join(fix, 'model.bim'), '--signals', File.join(run_dir, 'signals.json'),
        '--dm-spec', File.join(run_dir, 'dm-spec.json'), '--wb-spec', File.join(run_dir, 'workbook-spec.json'),
        '--classes', File.join(run_dir, 'measure-classes.json'), '--shaped-log', File.join(run_dir, 'pbi-shaped-model.json'),
        '--slicer-carry', File.join(run_dir, 'slicer-carry.json'), '--out-dir', rep_dir]
rout, rst = Open3.capture2e(env, RbConfig.ruby, File.join(scripts, 'pbi-shaped-report.rb'), *args)
File.write(File.join(work, 'report.log'), rout)
abort "drive.rb: pbi-shaped-report.rb failed\n#{rout}" unless rst.success?
puts 'drive.rb: ok'
