
module Autobots
  module Utils

    # Page object-related helper methods.
    module PageObjectHelper

      # Helper method to instantiate a new page object. This method should only
      # be used when first loading; subsequent page objects are automatically
      # instantiated by calling #cast on the page object.
      # Pass optional parameter Driver, which can be initialized in test and will override the global driver here.
      #
      # @param name [String, Driver]
      # @return [PageObject::Base]
      def page(name, override_driver=nil)
        # Get the fully-qualified class name
        klass_name = "autobots/page_objects/#{name}".camelize
        klass = begin
          klass_name.constantize
        rescue => exc
          msg = ""
          msg << "Cannot find page object '#{name}', "
          msg << "because could not load class '#{klass_name}' "
          msg << "with underlying error:\n  #{exc.class}: #{exc.message}\n"
          msg << exc.backtrace.map { |str| "    #{str}" }.join("\n")
          raise NameError, msg
        end

        # Get a default connector
        @driver = Autobots::Connector.get_default if override_driver.nil?
        @driver = override_driver if !override_driver.nil?
        instance = klass.new(@driver)

        # Before visiting the page, do any pre-processing necessary, if any,
        # but only visit the page if the pre-processing succeeds
        if block_given?
          retval = yield instance
          instance.go! if retval
        else
          instance.go! if override_driver.nil?
        end

        # similar like casting a page, necessary to validate some element on a page
        begin
          instance.validate!
        rescue Minitest::Assertion => exc
          raise Autobots::PageObjects::InvalidePageState, "#{klass}: #{exc.message}"
        end
        # Return the instance as-is
        instance
      end

      # Local teardown for page objects. Any page objects that are loaded will
      # be finalized upon teardown.
      #
      # @return [void]
      def teardown
        begin
          set_sauce_session_name if connector_is_saucelabs? && !@driver.nil?
          self.logger.debug "Finished setting saucelabs session name for #{name()}"
        rescue
          self.logger.debug "Failed setting saucelabs session name for #{name()}"
        end
        Autobots::Connector.finalize! if Autobots::Settings[:auto_finalize]
        super()
        print_sauce_link_if_fail
      end

      # Print out a link of a saucelabs's job when a test is not passed
      # Rescue to skip this step for tests like cube tracking
      def print_sauce_link_if_fail
        if !passed? && !skipped?
          puts '========================================================================================'
          begin
            puts "Find test on saucelabs: https://saucelabs.com/tests/#{@driver.session_id}"
          rescue
            puts 'can not retrieve driver session id, no link to saucelabs'
          end
        end
      end

      # update session name on saucelabs
      def set_sauce_session_name
        # identify the user who runs the tests and grab user's access_key
        # where are we parsing info from run command to in the code?
        connector = Autobots::Settings[:connector] # eg. saucelabs:phu:win7_ie11
        overrides = connector.to_s.split(/:/)
        new_tags = overrides[2]+"_by_"+overrides[1]
        file_name = overrides.shift
        path = Autobots.root.join('config', 'connectors')
        filepath  = path.join("#{file_name}.yml")
        raise ArgumentError, "Cannot load profile #{file_name.inspect} because #{filepath.inspect} does not exist" unless filepath.exist?

        cfg = YAML.load(File.read(filepath))
        cfg = Connector.resolve(cfg, overrides)
        cfg.freeze
        username = cfg["hub"]["user"]
        access_key = cfg["hub"]["pass"]

        require 'json'
        session_id = @driver.session_id
        http_auth = "https://#{username}:#{access_key}@saucelabs.com/rest/v1/#{username}/jobs/#{session_id}"
        # to_json need to: require "active_support/core_ext", but will mess up the whole framework, require 'json' in this method solved it
        body = {"name" => name(), "tags" => [new_tags]}.to_json
        # gem 'rest-client'
        RestClient.put(http_auth, body, {:content_type => "application/json"})
      end
      
      def connector_is_saucelabs?
        return true if Autobots::Settings[:connector].include?('saucelabs')
        return false
      end

      # Generic page object helper method to clear and send keys to a web element found by driver
      # @param [Element, String]
      def put_value(web_element, value)
        web_element.clear
        web_element.send_keys(value)
      end

      # Check if a web element exists on page or not, without wait
      # @param  eg. (:css, 'button.cancel') or (*BUTTON_GETSTARTED)
      # @param  also has an optional parameter-driver, which can be @element when calling this method in a widget object
      # @return [boolean]
      def is_element_present?(how, what, driver = nil)
        original_timeout = read_yml("config/connectors/saucelabs.yml", "timeouts:implicit_wait")
        @driver.manage.timeouts.implicit_wait = 0
        result = false
        parent_element = @driver if driver == nil
        parent_element = driver if driver != nil
        elements = parent_element.find_elements(how, what)
        begin
          if elements.size() > 0 && elements[0].displayed?
            result = true
          end
        rescue
          result = false
        end
        @driver.manage.timeouts.implicit_wait = original_timeout
        return result
      end

      # Helper method for retrieving value from yml file
      # todo should be moved to FileHelper.rb once we created this file in utils
      # @param [String, String]
      # keys, eg. "timeouts:implicit_wait"
      def read_yml(file_name, keys)
        data = Hash.new
        begin
          data = YAML.load_file "#{file_name}"
        rescue
          raise Exception, "File #{file_name} doesn't exist" unless File.exist?(file_name)
        rescue
          raise YAMLErrors, "Failed to load #{file_name}"
        end
        keys_array = keys.split(/:/)
        value = data
        keys_array.each do |key|
          value = value[key]
        end
        return value
      end

    end

  end
end
