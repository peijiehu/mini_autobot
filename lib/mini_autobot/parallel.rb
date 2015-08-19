module MiniAutobot
  class Parallel

    attr_reader :all_tests, :simultaneous_jobs

    def initialize(simultaneous_jobs, all_tests)
      @start_time = Time.now
      clean_result!

      @simultaneous_jobs = simultaneous_jobs
      @all_tests = all_tests

      connector = MiniAutobot.settings.connector
      @on_sauce = true if connector.include? 'saucelabs'
      @platform = connector.split(':')[2] || ''

      @pids = []
      @static_run_command = "mini_autobot -c #{MiniAutobot.settings.connector} -e #{MiniAutobot.settings.env}"
      tap_reporter_path = MiniAutobot.gem_root.join('lib/tapout/custom_reporters/fancy_tap_reporter.rb')
      @pipe_tap = "--tapy | tapout --no-color -r #{tap_reporter_path.to_s} fancytap"
    end

    # return true only if specified to run on mac in connector
    # @return [boolean]
    def run_on_mac?
      return true if @platform.include?('osx')
      return false
    end

    # remove all results files under logs/tap_results/
    def clean_result!
      IO.popen 'rm logs/tap_results/*'
      puts "Cleaning result files.\n"
    end

    def count_autobot_process
      counting_process = IO.popen "ps -ef | grep 'bin/#{@static_run_command}' -c"
      count_of_processes = counting_process.readlines[0].to_i - 1 # minus grep process
      count_of_processes
    end

    # run multiple commands with logging to start multiple tests in parallel
    # @param [Integer, Array]
    # n = number of tests will be running in parallel
    def run_in_parallel!
      # set number of tests to be running in parallel
      if simultaneous_jobs.nil?
        if run_on_mac?
          @simultaneous_jobs = 10 # saucelabs account limit for parallel is 10 for mac
        else
          @simultaneous_jobs = 20 # saucelabs account limit for parallel is 15 for non-mac
        end
      end

      size = all_tests.size
      if size <= simultaneous_jobs
        run_test_set(all_tests)
        puts "CAUTION! All #{size} tests are starting at the same time!"
        puts "will not really run it since computer will die" if size > 30
        sleep 20
      else
        first_test_set = all_tests[0, simultaneous_jobs]
        all_to_run = all_tests[(simultaneous_jobs + 1)...(all_tests.size - 1)]
        run_test_set(first_test_set)
        keep_running_full(all_to_run)
      end

      Process.waitall
      puts "\nAll Complete! Started at #{@start_time} and finished at #{Time.now}\n"
      exit
    end

    # runs each test from a test set in a separate child process
    def run_test_set(test_set)
      test_set.each do |test|
        run_command = "#{@static_run_command} -n #{test} #{@pipe_tap} > logs/tap_results/#{test}.t"
        pipe = IO.popen(run_command)
        puts "Running #{test}  #{pipe.pid}"
      end
    end

    def keep_running_full(all_to_run)
      puts "simultaneous_jobs = #{simultaneous_jobs}"
      running_subprocess_count = count_autobot_process - 1 # minus parent process
      while running_subprocess_count >= simultaneous_jobs
        puts "running_subprocess_count = #{running_subprocess_count} >= simultaneous_jobs = #{simultaneous_jobs}, wait 5 sec"
        sleep 5
        running_subprocess_count = count_autobot_process - 1
      end
      to_run_count = simultaneous_jobs - running_subprocess_count
      puts "got some space, run #{to_run_count} more"
      tests_to_run = all_to_run.slice!(0, to_run_count)
      run_test_set(tests_to_run)
      if all_to_run.size > 0
        keep_running_full(all_to_run)
      else
        return
      end
    end

    # @deprecated Use more native wait/check of Process
    def wait_for_pids(pids)
      running_pids = pids # assume all pids are running at this moment
      while running_pids.size > 1
        sleep 5
        puts "running_pids = #{running_pids}"
        running_pids.each do |pid|
          unless process_running?(pid)
            puts "#{pid} is not running, removing it from pool"
            running_pids.delete(pid)
          end
        end
      end
    end

    # @deprecated Too time consuming and fragile, should use more native wait/check of Process
    def wait_all_done_saucelabs
      size = all_tests.size
      job_statuses = saucelabs_last_n_statuses(size)
      while job_statuses.include?('in progress')
        puts "There are tests still running, waiting..."
        sleep 20
        job_statuses = saucelabs_last_n_statuses(size)
      end
    end

    private

    # call saucelabs REST API to get last #{limit} jobs' statuses
    # possible job status: complete, error, in progress
    def saucelabs_last_n_statuses(limit)
      connector = MiniAutobot.settings.connector # eg. saucelabs:phu:win7_ie11
      overrides = connector.to_s.split(/:/)
      file_name = overrides.shift
      path = MiniAutobot.root.join('config/mini_autobot', 'connectors')
      filepath  = path.join("#{file_name}.yml")
      raise ArgumentError, "Cannot load profile #{file_name.inspect} because #{filepath.inspect} does not exist" unless filepath.exist?
      cfg = YAML.load(File.read(filepath))
      cfg = Connector.resolve(cfg, overrides)
      cfg.freeze
      username = cfg["hub"]["user"]
      access_key = cfg["hub"]["pass"]

      require 'json'

      # call api to get most recent #{limit} jobs' ids
      http_auth = "https://#{username}:#{access_key}@saucelabs.com/rest/v1/#{username}/jobs?limit=#{limit}"
      response = get_response_with_retry(http_auth) # response was originally an array of hashs, but RestClient converts it to a string
      # convert response back to array
      response[0] = ''
      response[response.length-1] = ''
      array_of_hash = response.split(',')
      id_array = Array.new
      array_of_hash.each do |hash|
        hash = hash.gsub(':', '=>')
        hash = eval(hash)
        id_array << hash['id'] # each hash contains key 'id' and value of id
      end

      # call api to get job statuses
      statuses = Array.new
      id_array.each do |id|
        http_auth = "https://#{username}:#{access_key}@saucelabs.com/rest/v1/#{username}/jobs/#{id}"
        response = get_response_with_retry(http_auth)
        begin
          # convert response back to hash
          str = response.gsub(':', '=>')
          # this is a good example why using eval is dangerous, the string has to contain only proper Ruby syntax, here it has 'null' instead of 'nil'
          formatted_str = str.gsub('null', 'nil')
          hash = eval(formatted_str)
          statuses << hash['status']
        rescue SyntaxError
          puts "SyntaxError, response from saucelabs has syntax error"
        end
      end
      return statuses
    end

    def get_response_with_retry(url)
      retries = 5 # number of retries
      begin
        response = RestClient.get(url) # returns a String
      rescue
        puts "Failed at getting response from #{url} via RestClient \n Retrying..."
        retries -= 1
        retry if retries > 0
        response = RestClient.get(url) # retry the last time, fail if it still throws exception
      end
    end

    def process_running?(pid)
      begin
        Process.getpgid(pid)
        true
      rescue Errno::ESRCH
        false
      end
    end

  end
end
