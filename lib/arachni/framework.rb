# encoding: utf-8

=begin
    Copyright 2010-2013 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'rubygems'
require 'bundler/setup'

require 'ap'
require 'pp'

require File.expand_path( File.dirname( __FILE__ ) ) + '/options'

module Arachni

lib = Options.dir['lib']
require lib + 'version'
require lib + 'ruby'
require lib + 'error'
require lib + 'support'
require lib + 'utilities'
require lib + 'uri'
require lib + 'component/manager'
require lib + 'platform'
require lib + 'spider'
require lib + 'parser'
require lib + 'issue'
require lib + 'module'
require lib + 'plugin'
require lib + 'audit_store'
require lib + 'http'
require lib + 'report'
require lib + 'session'
require lib + 'trainer'

require Options.dir['mixins'] + 'progress_bar'

#
# The Framework class ties together all the components.
#
# It's the brains of the operation, it bosses the rest of the classes around.
# It runs the audit, loads modules and reports and runs them according to
# user options.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Framework
    #
    # include the output interface but try to use it as little as possible
    #
    # the UI classes should take care of communicating with the user
    #
    include UI::Output

    include Utilities
    include Mixins::Observable

    #
    # {Framework} error namespace.
    #
    # All {Framework} errors inherit from and live under it.
    #
    # When I say Framework I mean the {Framework} class, not the
    # entire Arachni Framework.
    #
    # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
    #
    class Error < Arachni::Error
    end

    # The version of this class.
    REVISION = '0.2.8'

    # How many times to request a page upon failure.
    AUDIT_PAGE_MAX_TRIES = 5

    # @return [Options] Instance options
    attr_reader :opts

    # @return   [Arachni::Report::Manager]
    attr_reader :reports

    # @return   [Arachni::Module::Manager]
    attr_reader :modules

    # @return   [Arachni::Plugin::Manager]
    attr_reader :plugins

    # @return   [Session]   Web application session manager.
    attr_reader :session

    # @return   [Spider]   Web application spider.
    attr_reader :spider

    # @return   [Arachni::HTTP]
    attr_reader :http

    # @return   [Array] URLs of all discovered pages.
    attr_reader :sitemap

    # @return   [Trainer]
    attr_reader :trainer

    # @return   [Integer]   Total number of pages added to their audit queue.
    attr_reader :page_queue_total_size

    # @return   [Integer]   Total number of urls added to their audit queue.
    attr_reader :url_queue_total_size

    # @return [Array<String>]
    #   Page URLs which elicited no response from the server and were not audited.
    #   Not determined by HTTP status codes, we're talking network failures here.
    attr_reader :failures

    #
    # @param    [Options]    opts
    # @param    [Block]      block
    #   Block to be passed a {Framework} instance which will then be {#reset}.
    #
    def initialize( opts = Arachni::Options.instance, &block )

        Encoding.default_external = 'BINARY'
        Encoding.default_internal = 'BINARY'

        @opts = opts

        @modules = Module::Manager.new( self )
        @reports = Report::Manager.new( @opts )
        @plugins = Plugin::Manager.new( self )

        @session = Session.new( @opts )
        reset_spider
        @http    = HTTP.instance

        reset_trainer

        # will store full-fledged pages generated by the Trainer since these
        # may not be be accessible simply by their URL
        @page_queue = Queue.new
        @page_queue_total_size = 0

        # will hold paths found by the spider in order to be converted to pages
        # and ultimately audited by the modules
        @url_queue = Queue.new
        @url_queue_total_size = 0

        # deep clone the redundancy rules to preserve their counter
        # for the reports
        @orig_redundant = @opts.redundant.deep_clone

        @running = false
        @status  = :ready
        @paused  = []

        @auditmap = []
        @sitemap  = []

        @current_url = ''

        # Holds page URLs which returned no response.
        @failures = []
        @retries  = {}

        if block_given?
            block.call self
            reset
        end
    end

    #
    # Starts the scan.
    #
    # @param   [Block]  block
    #   A block to call after the audit has finished but before running the reports.
    #
    def run( &block )
        prepare

        # catch exceptions so that if something breaks down or the user opted to
        # exit the reports will still run with whatever results Arachni managed to gather
        exception_jail( false ){ audit }

        clean_up
        exception_jail( false ){ block.call } if block_given?
        @status = :done

        # run reports
        @reports.run( audit_store ) if !@reports.empty?

        true
    end

    #
    # Runs loaded modules against a given `page`
    #
    # It will audit just the given page and not use the {Trainer} -- i.e. ignore
    # any new elements that might appear as a result.
    #
    # @param    [Page]    page
    #
    def audit_page( page )
        return if !page

        if skip_page? page
            print_info "Ignoring page due to exclusion criteria: #{page.url}"
            return false
        end

        @auditmap << page.url
        @sitemap |= @auditmap
        @sitemap.uniq!

        print_line
        print_status "Auditing: [HTTP: #{page.code}] #{page.url}"

        if page.platforms.any?
            print_info "Identified as: #{page.platforms.to_a.join( ', ' )}"
        end

        call_on_audit_page( page )

        @current_url = page.url.to_s

        @modules.schedule.each do |mod|
            wait_if_paused
            run_module_against_page( mod, page )
        end

        harvest_http_responses

        if !Module::Auditor.timeout_candidates.empty?
            print_line
            print_status "Verifying timeout-analysis candidates for: #{page.url}"
            print_info '---------------------------------------'
            Module::Auditor.timeout_audit_run
        end

        true
    end

    def on_audit_page( &block )
        add_on_audit_page( &block )
    end
    alias :on_run_mods :on_audit_page

    # @return   [Bool]
    #   `true` if the {Options#link_count_limit} has been reached, `false`
    #   otherwise.
    def link_count_limit_reached?
        @opts.link_count_limit_reached? @sitemap.size
    end

    #
    # Returns the following framework stats:
    #
    # *  `:requests`         -- HTTP request count
    # *  `:responses`        -- HTTP response count
    # *  `:time_out_count`   -- Amount of timed-out requests
    # *  `:time`             -- Amount of running time
    # *  `:avg`              -- Average requests per second
    # *  `:sitemap_size`     -- Number of discovered pages
    # *  `:auditmap_size`    -- Number of audited pages
    # *  `:progress`         -- Progress percentage
    # *  `:curr_res_time`    -- Average response time for the current burst of requests
    # *  `:curr_res_cnt`     -- Amount of responses for the current burst
    # *  `:curr_avg`         -- Average requests per second for the current burst
    # *  `:average_res_time` -- Average response time
    # *  `:max_concurrency`  -- Current maximum concurrency of HTTP requests
    # *  `:current_page`     -- URL of the currently audited page
    # *  `:eta`              -- Estimated time of arrival i.e. estimated remaining time
    #
    # @param    [Bool]  refresh_time    updates the running time of the audit
    #                                       (usefully when you want stats while paused without messing with the clocks)
    #
    # @param    [Bool]  override_refresh
    #
    # @return   [Hash]
    #
    def stats( refresh_time = false, override_refresh = false )
        req_cnt = http.request_count
        res_cnt = http.response_count

        @opts.start_datetime = Time.now if !@opts.start_datetime

        sitemap_sz  = @sitemap.size
        auditmap_sz = @auditmap.size

        if( !refresh_time || auditmap_sz == sitemap_sz ) && !override_refresh
            @opts.delta_time ||= Time.now - @opts.start_datetime
        else
            @opts.delta_time = Time.now - @opts.start_datetime
        end

        avg = 0
        avg = (res_cnt / @opts.delta_time).to_i if res_cnt > 0

        # We need to remove URLs that lead to redirects from the sitemap
        # when calculating the progress %.
        #
        # This is because even though these URLs are valid webapp paths
        # they are not actual pages and thus can't be audited;
        # so the sitemap and auditmap will never match and the progress will
        # never get to 100% which may confuse users.
        #
        sitemap_sz -= spider.redirects.size
        sitemap_sz = 0 if sitemap_sz < 0

        # Progress of audit is calculated as:
        #     amount of audited pages / amount of all discovered pages
        progress = (Float( auditmap_sz ) / sitemap_sz) * 100

        progress = Float( sprintf( '%.2f', progress ) ) rescue 0.0

        # Sometimes progress may slightly exceed 100% which can cause a few
        # strange stuff to happen.
        progress = 100.0 if progress > 100.0

        # Make sure to keep weirdness at bay.
        progress = 0.0 if progress < 0.0

        pb = Mixins::ProgressBar.eta( progress, @opts.start_datetime )

        {
            requests:         req_cnt,
            responses:        res_cnt,
            time_out_count:   http.time_out_count,
            time:             audit_store.delta_time,
            avg:              avg,
            sitemap_size:     auditstore_sitemap.size,
            auditmap_size:    auditmap_sz,
            progress:         progress,
            curr_res_time:    http.curr_res_time,
            curr_res_cnt:     http.curr_res_cnt,
            curr_avg:         http.curr_res_per_second,
            average_res_time: http.average_res_time,
            max_concurrency:  http.max_concurrency,
            current_page:     @current_url,
            eta:              pb
        }
    end

    #
    # Pushes a page to the page audit queue and updates {#page_queue_total_size}
    #
    # @param    [Page]  page
    #
    # @return   [Bool]
    #   `true` if push was successful, `false` if the `page` matched any
    #   exclusion criteria.
    #
    def push_to_page_queue( page )
        return false if skip_page? page

        @page_queue << page
        @page_queue_total_size += 1

        @sitemap |= [page.url]
        true
    end

    #
    # Pushes a URL to the URL audit queue and updates {#url_queue_total_size}
    #
    # @param    [String]  url
    #
    # @return   [Bool]
    #   `true` if push was successful, `false` if the `url` matched any
    #   exclusion criteria.
    #
    def push_to_url_queue( url )
        return false if skip_path? url

        abs = to_absolute( url )

        @url_queue.push( abs ? abs : url )
        @url_queue_total_size += 1

        @sitemap |= [url]
        false
    end

    #
    # @return    [AuditStore]   Scan results.
    #
    # @see AuditStore
    #
    def audit_store
        opts = @opts.to_hash.deep_clone

        # restore the original redundancy rules and their counters
        opts['redundant'] = @orig_redundant
        opts['mods'] = @modules.keys

        AuditStore.new(
            version:  version,
            revision: revision,
            options:  opts,
            sitemap:  (auditstore_sitemap || []).sort,
            issues:   @modules.results,
            plugins:  @plugins.results
        )
    end
    alias :auditstore :audit_store

    #
    # Runs a report component and returns the contents of the generated report.
    #
    # Only accepts reports which support an `outfile` option.
    #
    # @param    [String]    name
    #   Name of the report component to run, as presented by {#list_reports}'s
    #   `:shortname` key.
    # @param    [AuditStore]    external_report
    #   Report to use -- defaults to the local one.
    #
    # @return   [String]    Scan report.
    #
    # @raise    [Component::Error::NotFound]
    #   If the given report name doesn't correspond to a valid report component.
    #
    # @raise    [Component::Options::Error::Invalid]
    #   If the requested report doesn't format the scan results as a String.
    #
    def report_as( name, external_report = auditstore )
        if !@reports.available.include?( name.to_s )
            fail Component::Error::NotFound, "Report '#{name}' could not be found."
        end

        loaded = @reports.loaded
        begin
            @reports.clear

            if !@reports[name].has_outfile?
                fail Component::Options::Error::Invalid,
                     "Report '#{name}' cannot format the audit results as a String."
            end

            outfile = "/#{Dir.tmpdir}/arachn_report_as.#{name}"
            @reports.run_one( name, external_report, 'outfile' => outfile )

            IO.read( outfile )
        ensure
            File.delete( outfile ) if outfile
            @reports.clear
            @reports.load loaded
        end
    end

    # @return    [Array<Hash>]  Information about all available modules.
    def list_modules
        loaded = @modules.loaded

        begin
            @modules.clear
            @modules.available.map do |name|
                path = @modules.name_to_path( name )
                next if !lsmod_match?( path )

                @modules[name].info.merge(
                    mod_name:  name,
                    shortname: name,
                    author:    [@modules[name].info[:author]].
                                   flatten.map { |a| a.strip },
                    path:      path.strip
                )
            end.compact
        ensure
            @modules.clear
            @modules.load loaded
        end
    end
    alias :lsmod :list_modules

    # @return    [Array<Hash>]  Information about all available reports.
    def list_reports
        loaded = @reports.loaded

        begin
            @reports.clear
            @reports.available.map do |report|
                path = @reports.name_to_path( report )
                next if !lsrep_match?( path )

                @reports[report].info.merge(
                    rep_name:  report,
                    shortname: report,
                    path:      path,
                    author:    [@reports[report].info[:author]].
                                   flatten.map { |a| a.strip }
                )
            end.compact
        ensure
            @reports.clear
            @reports.load loaded
        end
    end
    alias :lsrep :list_reports

    # @return    [Array<Hash>]  Information about all available plugins.
    def list_plugins
        loaded = @plugins.loaded

        begin
            @plugins.clear
            @plugins.available.map do |plugin|
                path = @plugins.name_to_path( plugin )
                next if !lsplug_match?( path )

                @plugins[plugin].info.merge(
                    plug_name: plugin,
                    shortname: plugin,
                    path:      path,
                    author:    [@plugins[plugin].info[:author]].
                                   flatten.map { |a| a.strip }
                )
            end.compact
        ensure
            @plugins.clear
            @plugins.load loaded
        end
    end
    alias :lsplug :list_plugins

    # @return    [Array<Hash>]  Information about all available platforms.
    def list_platforms
        platforms = Platform::Manager.new
        platforms.valid.inject({}) do |h, platform|
            type = Platform::Manager::TYPES[platforms.find_type( platform )]
            h[type] ||= {}
            h[type][platform] = platforms.fullname( platform )
            h
        end
    end
    alias :lsplat :list_platforms

    # @return   [String]
    #   Status of the instance, possible values are (in order):
    #
    #   * `ready` -- Initialised and waiting for instructions.
    #   * `preparing` -- Getting ready to start (i.e. initing plugins etc.).
    #   * `crawling` -- The instance is crawling the target webapp.
    #   * `auditing` -- The instance is currently auditing the webapp.
    #   * `paused` -- The instance has been paused (if applicable).
    #   * `cleanup` -- The scan has completed and the instance is cleaning up
    #           after itself (i.e. waiting for plugins to finish etc.).
    #   * `done` -- The scan has completed, you can grab the report and shutdown.
    #
    def status
        return 'paused' if paused?
        @status.to_s
    end

    # @return   [Bool]  `true` if the framework is running, `false` otherwise.
    def running?
        @running
    end

    # @return   [Bool]  `true` if the framework is paused or in the process of.
    def paused?
        !@paused.empty?
    end

    # @return   [TrueClass]
    #   Pauses the framework on a best effort basis, might take a while to take effect.
    def pause
        spider.pause
        @paused << caller
        true
    end

    # @return   [TrueClass]  Resumes the scan/audit.
    def resume
        @paused.delete( caller )
        spider.resume
        true
    end

    # @return    [String]   Returns the version of the framework.
    def version
        Arachni::VERSION
    end

    # @return    [String]   Returns the revision of the {Framework} (this) class.
    def revision
        REVISION
    end

    #
    # Cleans up the framework; should be called after running the audit or
    # after canceling a running scan.
    #
    # It stops the clock and waits for the plugins to finish up.
    #
    def clean_up
        @status = :cleanup

        @opts.finish_datetime  = Time.now
        @opts.start_datetime ||= Time.now

        @opts.delta_time = @opts.finish_datetime - @opts.start_datetime

        # make sure this is disabled or it'll break report output
        disable_only_positives

        @running = false

        # wait for the plugins to finish
        @plugins.block

        true
    end

    def reset_spider
        @spider = Spider.new( @opts )
    end

    def reset_trainer
        @trainer = Trainer.new( self )
    end

    #
    # Resets everything and allows the framework to be re-used.
    #
    # You should first update {Arachni::Options}.
    #
    # Prefer this if you already have an instance.
    #
    def reset
        @page_queue_total_size = 0
        @url_queue_total_size  = 0
        @failures.clear
        @retries.clear
        @sitemap.clear

        # this needs to be first so that the HTTP lib will be reset before
        # the rest
        self.class.reset

        clear_observers
        reset_trainer
        reset_spider
        @modules.clear
        @reports.clear
        @plugins.clear
    end

    #
    # Resets everything and allows the framework to be re-used.
    #
    # You should first update {Arachni::Options}.
    #
    def self.reset
        UI::Output.reset_output_options
        Platform::Manager.reset
        Module::Auditor.reset
        ElementFilter.reset
        Element::Capabilities::Auditable.reset
        Module::Manager.reset
        Plugin::Manager.reset
        Report::Manager.reset
        HTTP.reset
    end

    private

    #
    # Prepares the framework for the audit.
    #
    # Sets the status to 'running', starts the clock and runs the plugins.
    #
    # Must be called just before calling {#audit}.
    #
    def prepare
        @status = :preparing
        @running = true
        @opts.start_datetime = Time.now

        # run all plugins
        @plugins.run
    end

    #
    # Performs the audit
    #
    # Runs the spider, pushes each page or url to their respective audit queue,
    # calls {#audit_queues}, runs the timeout attacks ({Arachni::Module::Auditor.timeout_audit_run}) and finally re-runs
    # {#audit_queues} in case the timing attacks uncovered a new page.
    #
    def audit
        wait_if_paused

        @status = :crawling

        # if we're restricted to a given list of paths there's no reason to run the spider
        if @opts.restrict_paths && !@opts.restrict_paths.empty?
            @opts.restrict_paths = @opts.restrict_paths.map { |p| to_absolute( p ) }
            @sitemap = @opts.restrict_paths.dup
            @opts.restrict_paths.each { |url| push_to_url_queue( url ) }
        else
            # initiates the crawl
            spider.run do |page|
                @sitemap |= spider.sitemap
                push_to_url_queue page.url

                next if page.platforms.empty?
                print_info "Identified as: #{page.platforms.to_a.join( ', ' )}"
            end
        end

        audit_queues
    end

    #
    # Audits the URL and Page queues
    #
    def audit_queues
        return if modules.empty?

        @status = :auditing

        # goes through the URLs discovered by the spider, repeats the request
        # and parses the responses into page objects
        #
        # yes...repeating the request is wasteful but we can't store the
        # responses of the spider to consume them here because there's no way
        # of knowing how big the site will be.
        #
        while !@url_queue.empty?
            page = Page.from_url( @url_queue.pop, precision: 2 )

            @retries[page.url.hash] ||= 0

            if page.code == 0
                if @retries[page.url.hash] >= AUDIT_PAGE_MAX_TRIES
                    @failures << page.url

                    print_error "Giving up trying to audit: #{page.url}"
                    print_error "Couldn't get a response after #{AUDIT_PAGE_MAX_TRIES} tries."
                else
                    print_bad "Retrying for: #{page.url}"
                    @retries[page.url.hash] += 1
                    @url_queue << page.url
                end

                next
            end

            push_to_page_queue Page.from_url( page.url, precision: 2 )
            audit_page_queue
        end

        audit_page_queue
    end

    #
    # Audits the page queue
    #
    def audit_page_queue
        # this will run until no new elements appear for the given page
        audit_page( @page_queue.pop ) while !@page_queue.empty?
    end

    #
    # Special sitemap for the {#auditstore}.
    #
    # Used only under special circumstances, will usually return the {#sitemap}
    # but can be overridden by the {::Arachni::RPC::Framework}.
    #
    # @return   [Array]
    #
    def auditstore_sitemap
        @sitemap
    end

    def caller
        if /^(.+?):(\d+)(?::in `(.*)')?/ =~ ::Kernel.caller[1]
            Regexp.last_match[1]
        end
    end

    def wait_if_paused
        ::IO::select( nil, nil, nil, 1 ) while paused?
    end

    def harvest_http_responses
        print_status 'Harvesting HTTP responses...'
        print_info 'Depending on server responsiveness and network' <<
            ' conditions this may take a while.'

        # Run all the queued HTTP requests and harvest the responses.
        http.run

        # Needed for some HTTP callbacks.
        http.run

        session.ensure_logged_in
    end

    #
    # Passes a page to the module and runs it.
    # It also handles any exceptions thrown by the module at runtime.
    #
    # @see Page
    #
    # @param    [Arachni::Module::Base]   mod      the module to run
    # @param    [Page]    page
    #
    def run_module_against_page( mod, page )
        begin
            @modules.run_one( mod, page )
        rescue SystemExit
            raise
        rescue => e
            print_error "Error in #{mod.to_s}: #{e.to_s}"
            print_error_backtrace e
        end
    end

    def lsrep_match?( path )
        regexp_array_match( @opts.lsrep, path )
    end

    def lsmod_match?( path )
        regexp_array_match( @opts.lsmod, path )
    end

    def lsplug_match?( path )
        regexp_array_match( @opts.lsplug, path )
    end

    def regexp_array_match( regexps, str )
        cnt = 0
        regexps.each { |filter| cnt += 1 if str =~ filter }
        cnt == regexps.size
    end

end
end
