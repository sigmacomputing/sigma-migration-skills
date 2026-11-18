# frozen_string_literal: true
# TEST-ONLY helper: environment + call-log readers for running the real scripts against test/support/fake_net.rb.

require 'json'
require 'tmpdir'
require 'fileutils'

module FakeRun
  SUPPORT = File.expand_path('fake_net.rb', __dir__)
  FIXTURE = File.expand_path('../../fixtures/orders-overview', __dir__)

  module_function

  # RUBYOPT splits on whitespace and cannot quote, and this checkout's path may contain spaces: preload the fake
  # through a space-free symlink.
  def preload_path
    @preload_path ||= begin
      dir = Dir.mktmpdir('omni-fake-net')
      link = File.join(dir, 'fake_net.rb')
      File.symlink(SUPPORT, link)
      at_exit { FileUtils.rm_rf(dir) }
      link
    end
  end

  # Env for a child process: no network, Sigma answered by FakeServices, state in `state_dir`.
  def env(state_dir, extra: {})
    base = { 'RUBYOPT' => "-r#{preload_path}", 'FAKE_STATE_DIR' => state_dir,
             'SIGMA_BASE_URL' => 'https://fake.sigmacomputing.com', 'SIGMA_API_TOKEN' => 'fake-token',
             'SIGMA_AUTH_MODE' => 'client-credentials', 'SIGMA_TOKEN_MINTED_AT' => '', 'SIGMA_CLI_PROFILE' => '',
             'OMNI_BASE_URL' => '', 'OMNI_API_KEY' => '',
             'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8' }
    base.merge(extra)
  end

  def calls(state_dir)
    f = File.join(state_dir, 'calls.jsonl')
    File.file?(f) ? File.readlines(f).map { |l| JSON.parse(l) } : []
  end

  def count(state_dir, method, path_prefix)
    calls(state_dir).count { |c| c['method'] == method && c['path'].start_with?(path_prefix) }
  end
end
