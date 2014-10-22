require './app/rapid_connect'

describe RapidConnect do
  def stringify_keys(hash)
    hash.reduce({}) { |a, (k, v)| a.merge(k.to_s => v) }
  end

  def reload_service
    json = @redis.hget('serviceproviders', identifier)
    RapidConnectService.new.from_json(json)
  end

  before :all do
    File.open('/tmp/rspec_organisations.json', 'w') { |f| f.write(JSON.generate ['Test Org Name', 'Another Test Org Name']) }
  end

  after :all do
    File.delete('/tmp/rspec_organisations.json')
  end

  before :each do
    @valid_shibboleth_headers = {
      'HTTP_SHIB_SESSION_ID' => 'abcd1234',
      'HTTP_PERSISTENT_ID' => 'https://idp.example.com!https://sp.example.com!0987zyxw',
      'HTTP_CN' => 'Test User',
      'HTTP_DISPLAYNAME' => 'Mr Test J User',
      'HTTP_GIVENNAME' => 'Test',
      'HTTP_SN' => 'User',
      'HTTP_MAIL' => 'testuser@example.com',
      'HTTP_EPPN' => 'tuser1@example.com',
      'HTTP_AFFILIATION' => 'staff@example.com',
      'HTTP_AUEDUPERSONSHAREDTOKEN' => 'shared_token'
    }

    @valid_subject = {
      principal: @valid_shibboleth_headers['HTTP_PERSISTENT_ID'],
      cn: @valid_shibboleth_headers['HTTP_CN'],
      display_name: @valid_shibboleth_headers['HTTP_DISPLAYNAME'],
      given_name: @valid_shibboleth_headers['HTTP_GIVENNAME'],
      surname: @valid_shibboleth_headers['HTTP_SN'],
      mail: @valid_shibboleth_headers['HTTP_MAIL'],
      principal_name: @valid_shibboleth_headers['HTTP_EPPN'],
      scoped_affiliation: @valid_shibboleth_headers['HTTP_AFFILIATION'],
      shared_token: @valid_shibboleth_headers['HTTP_AUEDUPERSONSHAREDTOKEN']
    }

    @non_administrator = @valid_subject
      .merge(principal: 'https://idp.example.com!-!1234abcd')

    @redis =  Redis.new
  end

  after :each do
    flush_stores
  end

  def administrator
    @redis.hset('administrators', @valid_subject[:principal], { 'name' => @valid_subject[:cn], 'mail' => @valid_subject[:mail] }.to_json)
  end

  def exampleservice(opts = {})
    @redis.hset('serviceproviders', '1234abcd', opts.reverse_merge('name' => 'Our Web App', 'audience' => 'https://service.com', 'endpoint' => 'https://service.com/auth/jwt', 'secret' => 'ykUlP1XMq3RXMd9w').to_json)
  end

  def enableexampleservice(opts = {})
    exampleservice(opts)
    service_provider = JSON.parse(@redis.hget('serviceproviders', '1234abcd'))
    service_provider[:enabled] = true
    @redis.hset('serviceproviders', '1234abcd', service_provider.to_json)
  end

  describe '/' do
    it 'shows welcome erb' do
      get '/'
      expect(last_response).to be_ok
      expect(last_response.body).to contain('Welcome to AAF Rapid Connect')
    end
  end

  describe '/developers' do
    it 'shows developers guide' do
      get '/developers'
      expect(last_response).to be_successful
      expect(last_response.body)
        .to contain('Integrating with AAF Rapid Connect')
    end
  end

  describe '/login' do
    it 'redirects to Shibboleth SP SSO on login request' do
      get '/login/1'
      expect(last_response).to be_redirect
      expect(last_response.location).to eq('http://example.org/Shibboleth.sso/Login?target=/login/shibboleth/1')
    end

    it 'sends a 403 response if Shibboleth SP login response contains no session id' do
      get '/login/shibboleth/1'
      expect(last_response.status).to eq(403)
    end

    it 'sends a redirect to service unknown if original target not in session' do
      get '/login/shibboleth/1', {}, @valid_shibboleth_headers
      expect(last_response).to be_redirect
      expect(last_response.location).to eq('http://example.org/serviceunknown')
      follow_redirect!
      expect(last_response.body).to contain('Service Unknown')
    end

    it 'sends a redirect to the original target and populates subject into session when there is a valid Shibboleth SP response' do
      target = 'http://example.org/jwt/authnrequest'
      get '/login/shibboleth/1', {}, { 'rack.session' => { target: { '1' => target } } }.merge(@valid_shibboleth_headers)
      expect(last_response).to be_redirect
      expect(last_response.location).to eq(target)
      expect(session[:target]).to be_empty
      expect(session[:subject][:principal]).to eq(@valid_shibboleth_headers['HTTP_PERSISTENT_ID'])
      expect(session[:subject][:cn]).to eq(@valid_shibboleth_headers['HTTP_CN'])
      expect(session[:subject][:display_name]).to eq(@valid_shibboleth_headers['HTTP_DISPLAYNAME'])
      expect(session[:subject][:given_name]).to eq(@valid_shibboleth_headers['HTTP_GIVENNAME'])
      expect(session[:subject][:surname]).to eq(@valid_shibboleth_headers['HTTP_SN'])
      expect(session[:subject][:mail]).to eq(@valid_shibboleth_headers['HTTP_MAIL'])
      expect(session[:subject][:principal_name]).to eq(@valid_shibboleth_headers['HTTP_EPPN'])
      expect(session[:subject][:scoped_affiliation]).to eq(@valid_shibboleth_headers['HTTP_AFFILIATION'])
      expect(session[:subject][:shared_token]).to eq(@valid_shibboleth_headers['HTTP_AUEDUPERSONSHAREDTOKEN'])
    end
  end

  describe '/logout' do
    it 'performs logout correctly' do
      get '/logout', {}, 'rack.session' => { subject: { cn: 'Test User' } }
      expect(session[:subject]).to be_nil
      expect(last_response).to be_redirect
      expect(last_response.location).to eq('http://example.org/')
    end
  end

  describe '/registration' do
    it 'directs to login if registration attempted when unauthenticated' do
      allow(SecureRandom).to receive(:urlsafe_base64).and_return('1')
      get '/registration'
      expect(last_response).to be_redirect
      expect(last_response.location).to eq('http://example.org/login/1')
    end

    it 'shows the registration screen' do
      get '/registration', {}, 'rack.session' => { subject: @valid_subject }
      expect(last_response).to be_ok
      expect(last_response.body).to contain('Service Registration')
    end

    context '/save' do
      before do
        allow(SecureRandom).to receive(:urlsafe_base64).and_return(identifier)
        @valid_subject.merge!(cn: attrs[:registrant_name],
                              mail: attrs[:registrant_mail])
      end

      let(:identifier) { '1234abc' }
      let(:base_attrs) { attributes_for(:rapid_connect_service) }
      let(:attrs) { base_attrs }

      let(:params) do
        attrs.select do |k, _|
          %i(name audience endpoint secret organisation).include?(k)
        end
      end

      let(:rack_env) { { 'rack.session' => { subject: @valid_subject } } }

      def run
        post '/registration/save', params, rack_env
      end

      shared_examples 'a failed registration' do |opts = {}|
        it 'is rejected' do
          run
          expect(last_response.body).to contain('Service Registration')
          expect(last_response.body)
            .to contain(opts[:message] || 'Invalid data supplied')
        end

        it 'does not create a service' do
          expect { run }.not_to change { @redis.hlen('serviceproviders') }
        end
      end

      context 'with an invalid endpoint' do
        let(:attrs) { base_attrs.merge(endpoint: 'example.com/auth') }
        it_behaves_like 'a failed registration'
      end

      context 'with an invalid audience' do
        let(:attrs) { base_attrs.merge(audience: 'example.com/auth') }
        it_behaves_like 'a failed registration'
      end

      context 'with no organisation' do
        let(:attrs) { base_attrs.merge(organisation: nil) }
        it_behaves_like 'a failed registration'
      end

      context 'when an identifier collides' do
        before { @redis.hset('serviceproviders', identifier, '{}') }
        it_behaves_like 'a failed registration',
                        message: 'Invalid identifier generated. ' \
                                 'Please re-submit registration.'
      end

      context 'with an excessively short secret' do
        let(:attrs) { base_attrs.merge(secret: 'tooshort') }
        it_behaves_like 'a failed registration'
      end

      shared_examples 'a successful registration' do |opts|
        before { attrs.merge!(enabled: opts[:enabled]) }

        it 'creates the service' do
          expect { run }.to change { @redis.hlen('serviceproviders') }.by(1)
          json = @redis.hget('serviceproviders', identifier)
          expect(json).not_to be_nil

          expect(JSON.load(json)).to eq(stringify_keys(attrs))
        end

        it 'redirects to the completed registration page' do
          run
          expect(last_response).to be_redirect
          expect(last_response.location)
            .to eq('http://example.org/registration/complete')
          follow_redirect!
          expect(last_response.body).to contain(opts[:message])
        end

        it 'ignores a provided service type' do
          attrs.merge!(type: 'auresearch')
          run
          expect(reload_service.type).to eq('research')
        end
      end

      context 'in production' do
        before { RapidConnect.set :federation, 'production' }

        it 'sends an email' do
          run
          is_expected.to have_sent_email
          expect(last_email.to).to include('support@example.org')
          expect(last_email.from).to include('noreply@example.org')
          expect(last_email.subject)
            .to eq('New service registration for AAF Rapid Connect')
          expect(last_email.html_part).to contain(@valid_subject[:cn])
        end

        it_behaves_like 'a successful registration',
                        enabled: false,
                        message: 'Service Registration Complete'
      end

      context 'in test' do
        before { RapidConnect.set :federation, 'test' }

        it 'sends no email' do
          run
          is_expected.not_to have_sent_email
        end

        it_behaves_like 'a successful registration',
                        enabled: true,
                        message: 'Service Registered and automatically approved'
      end
    end
  end

  context '/administration' do
    before { administrator }

    it 'directs to login if administration url requested when unauthenticated' do
      allow(SecureRandom).to receive(:urlsafe_base64).and_return('1')
      get '/administration/xyz'
      expect(last_response).to be_redirect
      expect(last_response.location).to eq('http://example.org/login/1')
    end

    it 'halts with 403 if administration url requested when authenticated user is not an administrator' do
      get '/administration/xyz', {}, 'rack.session' => { subject: @non_administrator }
      expect(last_response.status).to eq(403)
    end

    it 'shows the administration dashboard' do
      administrator
      get '/administration', {}, 'rack.session' => { subject: @valid_subject }
      expect(last_response).to be_ok
      expect(last_response.body).to contain('Administration')
    end

    context '/services' do
      let!(:service) { build(:rapid_connect_service, type: type) }
      let(:type) { 'research' }
      let(:rack_env) { { 'rack.session' => { subject: @valid_subject } } }
      let(:url) { '/administration/services' }
      let(:method) { :get }
      let(:params) { {} }
      let(:identifier) { '1234abcd' }
      let(:base_attrs) { attributes_for(:rapid_connect_service) }
      let(:attrs) { base_attrs }

      before { @redis.hset('serviceproviders', identifier, service.to_json) }
      subject { last_response }

      def run
        send(method, url, params, rack_env)
      end

      it 'lists all current services' do
        run
        expect(subject).to be_successful
        expect(subject).to contain(service.name)
        expect(subject).to contain('Show')
      end

      context '/:identifier' do
        before { run }

        context 'with an invalid identifier' do
          let(:url) { '/administration/services/invalidid' }
          it { is_expected.to be_not_found }
        end

        context 'with a valid identifier' do
          let(:url) { '/administration/services/1234abcd' }

          it 'shows a specific service' do
            expect(subject).to be_successful
            expect(subject).to contain(service.name)
            expect(subject).to contain('Edit')
            expect(subject).to contain('Delete')
          end

          shared_context 'endpoint display' do
            it 'shows the endpoint' do
              endpoint = "/jwt/authnrequest/#{service.type}/#{identifier}"
              expect(subject).to contain(endpoint)
            end
          end

          context 'for a research service' do
            include_context 'endpoint display'
          end

          context 'for an auresearch service' do
            let(:type) { 'auresearch' }
            include_context 'endpoint display'
          end

          context 'for a zendesk service' do
            let(:type) { 'zendesk' }
            include_context 'endpoint display'
          end
        end
      end

      context '/edit/:identifier' do
        before { run }

        context 'with an invalid identifier' do
          let(:url) { '/administration/services/edit/invalidid' }
          it { is_expected.to be_not_found }
        end

        context 'with a valid identifier' do
          let(:url) { '/administration/services/edit/1234abcd' }

          it 'shows a specific service' do
            expect(subject).to be_successful
            expect(subject).to contain("Editing #{service.name}")
            expect(subject).to contain('Update Service')
            expect(subject).to contain('Cancel')
          end
        end
      end

      context '/update' do
        let(:method) { :put }
        let(:url) { '/administration/services/update' }
        let(:params) { attrs.merge(identifier: identifier) }

        shared_examples 'a failed update' do
          it 'is rejected' do
            run
            expect(flash[:error]).to eq('Invalid data supplied')
            expect(subject).to be_redirect
            expect(subject.location).to end_with('/administration/services')
          end

          it 'does not create a service' do
            expect { run }.not_to change { @redis.hlen('serviceproviders') }
          end
        end

        context 'with an invalid endpoint' do
          let(:attrs) { base_attrs.merge(endpoint: 'example.com/auth') }
          it_behaves_like 'a failed update'
        end

        context 'with an invalid audience' do
          let(:attrs) { base_attrs.merge(audience: 'example.com/auth') }
          it_behaves_like 'a failed update'
        end

        context 'with no organisation' do
          let(:attrs) { base_attrs.merge(organisation: nil) }
          it_behaves_like 'a failed update'
        end

        context 'with an excessively short secret' do
          let(:attrs) { base_attrs.merge(secret: 'tooshort') }
          it_behaves_like 'a failed update'
        end

        context 'with an invalid identifier' do
          let(:params) { attrs.merge(identifier: 'nonexistent_sevice') }
          it_behaves_like 'a failed update'
        end

        it 'updates the service' do
          old_attrs = service.attributes

          expect { run }.to change { reload_service.attributes }
            .from(stringify_keys(old_attrs)).to(stringify_keys(attrs))
        end

        it 'updates the service type' do
          params.merge!(type: 'auresearch')
          expect { run }.to change { reload_service.type }
            .from('research').to('auresearch')
        end
      end

      context '/toggle/:identifier' do
        let(:method) { :patch }
        let(:url) { '/administration/services/toggle/1234abcd' }

        context 'with a disabled service' do
          let(:service) { build(:rapid_connect_service, enabled: false) }

          it 'enables the service' do
            expect { run }.to change { reload_service.enabled }
              .from(false).to(true)
          end

          it 'redirects to the service' do
            run
            expect(subject).to be_redirect
            expect(subject.location)
              .to end_with("/administration/services/#{identifier}")
          end
        end

        context 'with an enabled service' do
          let(:service) { build(:rapid_connect_service, enabled: true) }

          it 'disables the service' do
            expect { run }.to change { reload_service.enabled }
              .from(true).to(false)
          end

          it 'redirects to the service' do
            run
            expect(subject).to be_redirect
            expect(subject.location)
              .to end_with("/administration/services/#{identifier}")
          end
        end

        context 'with an unknown service' do
          let(:identifier) { 'nonexistent_service' }

          before { run }
          it { is_expected.to be_not_found }
        end
      end

      context '/delete/:identifier' do
        let(:method) { :delete }

        context 'with an invalid identifier' do
          before { run }
          let(:url) { '/administration/services/delete/nonexistent_service' }
          it { is_expected.to be_not_found }
        end

        context 'with a valid identifier' do
          let(:url) { '/administration/services/delete/1234abcd' }

          it 'deletes the service' do
            expect { run }.to change { @redis.hlen('serviceproviders') }.by(-1)
            expect(@redis.hexists('serviceproviders', identifier)).to be_falsey
          end

          it 'redirects to the services list' do
            run
            expect(subject).to be_redirect
            expect(subject.location).to end_with('/administration/services')
          end
        end
      end
    end

    describe '/administrators' do
      it 'lists all current administrators' do
        administrator
        get '/administration/administrators', {}, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_ok
        expect(last_response.body).to contain(@valid_subject[:principal])
        expect(last_response.body).to contain('Delete')
      end

      it 'allows administrators to be created' do
        administrator
        get '/administration/administrators/create', {}, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_ok
        expect(last_response.body).to contain('Create Administrator')
      end

      it 'prevents new administrator if no identifier' do
        administrator
        post '/administration/administrators/save', {}, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_ok
        expect(last_response.body).to contain('Invalid form data')
      end

      it 'prevents duplicate administrators from being saved' do
        administrator
        @redis.hset('administrators', 'https://idp.example.com!https://sp.example.com!dummy', { 'name' => 'Dummy User', 'mail' => 'dummy@example.org' }.to_json)

        post '/administration/administrators/save', { 'identifier' => 'https://idp.example.com!https://sp.example.com!dummy' }, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_redirect
        expect(last_response.location).to eq('http://example.org/administration/administrators')
        follow_redirect!
        expect(last_response.body).to contain('Administrator already exists')
      end

      it 'prevents new administrator if name and mail not supplied' do
        administrator
        post '/administration/administrators/save', { 'identifier' => 'https://idp.example.com!https://sp.example.com!dummy', 'name' => '' }, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_ok
        expect(last_response.body).to contain('Invalid form data')
      end

      it 'creates new administrator' do
        administrator
        expect(@redis.hlen('administrators')).to eq(1)
        post '/administration/administrators/save', { 'identifier' => 'https://idp.example.com!https://sp.example.com!dummy', 'name' => 'Dummy User', 'mail' => 'dummy@example.org' }, 'rack.session' => { subject: @valid_subject }
        expect(@redis.hlen('administrators')).to eq(2)
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_response.body).to contain('Administrator added')
      end

      it 'prevents administrator delete if no identifier' do
        administrator
        delete '/administration/administrators/delete', {}, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_redirect
        expect(last_response.location).to eq('http://example.org/administration/administrators')
        follow_redirect!
        expect(last_response.body).to contain('Invalid form data')
      end

      it 'prevents administrator delete if identifier matches current administrator' do
        administrator
        delete '/administration/administrators/delete', { 'identifier' => @valid_subject[:principal] }, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_redirect
        expect(last_response.location).to eq('http://example.org/administration/administrators')
        follow_redirect!
        expect(last_response.body).to contain('Removing your own access is not supported')
      end

      it 'provides an error when no such administrator is requested to be deleted' do
        administrator
        delete '/administration/administrators/delete', { 'identifier' => 'https://idp.example.com!https://sp.example.com!dummy' }, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_redirect
        expect(last_response.location).to eq('http://example.org/administration/administrators')
        expect(@redis.hlen('administrators')).to eq(1)
        follow_redirect!
        expect(last_response.body).to contain('No such administrator')
      end

      it 'deletes a current administrator' do
        administrator
        @redis.hset('administrators', 'https://idp.example.com!https://sp.example.com!dummy', { 'name' => 'Dummy User', 'mail' => 'dummy@example.org' }.to_json)
        expect(@redis.hlen('administrators')).to eq(2)
        delete '/administration/administrators/delete', { 'identifier' => 'https://idp.example.com!https://sp.example.com!dummy' }, 'rack.session' => { subject: @valid_subject }
        expect(last_response).to be_redirect
        expect(last_response.location).to eq('http://example.org/administration/administrators')
        expect(@redis.hlen('administrators')).to eq(1)
        follow_redirect!
        expect(last_response.body).to contain('Administrator deleted successfully')
      end
    end
  end

  context '/jwt' do
    context 'with no authenticated user' do
      it 'directs to login' do
        get '/jwt/xyz'
        expect(last_response).to be_redirect
        expect(last_response.location)
          .to start_with('http://example.org/login/')
      end
    end

    shared_examples 'a valid service type' do
      let(:service) { create(:rapid_connect_service, type: type) }
      let(:identifier) { service.identifier }
      let(:principal) { @valid_subject[:principal] }
      let(:env) { { 'rack.session' => { subject: @valid_subject } } }

      def binding(*parts)
        ['urn:mace:aaf.edu.au:rapid.aaf.edu.au', *parts].join(':')
      end

      let(:audit_line) do
        [
          Time.now.utc.strftime('%Y%m%dT%H%M%SZ'), binding(type, 'get'),
          service.identifier, service.audience, binding('jwt', type, 'sso'),
          RapidConnect.settings.issuer, binding('jwt', type, 'post'), 'x',
          principal, 'urn:oasis:names:tc:SAML:2.0:ac:classes:XMLDSig',
          attrs.sort.join(','), '', '', ''
        ].join('|')
      end

      subject { run }

      around { |example| Timecop.freeze { example.run } }

      def run
        get "/jwt/authnrequest/#{type}/#{identifier}", {}, env
      end

      context 'for a nonexistent service' do
        let(:identifier) { 'nonexistent' }
        it { is_expected.to be_not_found }
      end

      context 'for the wrong service type' do
        let(:service) { create(:rapid_connect_service, type: 'wrong') }
        it { is_expected.to be_not_found }
      end

      context 'for a blank identifier' do
        let(:identifier) { '' }
        it { is_expected.to be_not_found }
      end

      context 'for a disabled service' do
        let(:service) do
          create(:rapid_connect_service, type: type, enabled: false)
        end
        it { is_expected.to be_forbidden }
      end

      it 'creates a session' do
        run
        expect(last_response.headers).to include('Set-Cookie')
        expect(last_response.headers['Set-Cookie']).to match(/rack.session=/)
        expect(last_response.headers['Set-Cookie']).to match(/HttpOnly/)
        expect(last_response.headers['Set-Cookie']).not_to match(/expires=/)
      end

      it 'records the retargeted eptid' do
        hash = OpenSSL::Digest::SHA256.hexdigest(principal)
        aud = service.audience
        @redis.set("eptid:#{aud}:#{hash}", 'x')

        run

        log_lines = File.readlines(app.settings.app_logfile)
        expect(log_lines.last(2).first.strip)
          .to end_with("Retargeted principal #{principal} for #{aud} as x")
      end

      it 'records an audit log entry' do
        allow(SecureRandom).to receive(:urlsafe_base64).and_return('x')
        run

        audit_lines = File.readlines(app.settings.audit_logfile)
        expect(audit_lines.last.strip).to end_with(audit_line)
      end
    end

    shared_context 'a research service type' do
      it_behaves_like 'a valid service type' do
        it 'creates a JWT' do
          run
          expect(last_response).to be_successful
          expect(last_response.body)
            .to contain('AAF Rapid Connect - Redirection')
        end
      end
    end

    context '/authnrequest/research' do
      let(:type) { 'research' }
      let(:attrs) do
        %w(cn mail displayname givenname surname edupersontargetedid
           edupersonscopedaffiliation edupersonprincipalname)
      end

      include_context 'a research service type'
    end

    context '/authnrequest/auresearch' do
      let(:type) { 'auresearch' }
      let(:attrs) do
        %w(cn mail displayname givenname surname edupersontargetedid
           edupersonscopedaffiliation edupersonprincipalname
           auedupersonsharedtoken)
      end

      include_context 'a research service type'
    end

    context '/authnrequest/zendesk' do
      let(:type) { 'zendesk' }
      let(:attrs) { %w(cn mail edupersontargetedid o) }

      it_behaves_like 'a valid service type' do
        it 'creates a JWT' do
          run
          expect(last_response).to be_redirect
          expect(last_response.location)
            .to match(/#{service.endpoint}\?jwt=.+&return_to=.*/)
        end
      end
    end
  end

  shared_examples_for 'export API' do
    context 'export disabled' do
      it '404' do
        begin
          Sinatra::Base.set :export, enabled: false
          get '/export/services'
          expect(last_response.status).to eq 404
        ensure
          Sinatra::Base.set :export, enabled: true
        end
      end
    end

    context 'export enabled' do
      context 'authorize header malformed' do
        it '403 if not supplied' do
          get '/export/services'
          expect(last_response.status).to eq 403
        end

        it '403 if not formed correctly' do
          get '/export/services', 'HTTP_AUTHORIZATION' => 'invalid content'
          expect(last_response.status).to eq 403
        end
      end

      context 'authorize header correctly formed' do
        context 'invalid secret' do
          it '403' do
            get '/export/services', nil, 'HTTP_AUTHORIZATION' => 'AAF-RAPID-EXPORT service="test", key="wrong_secret"'
            expect(last_response.status).to eq 403
          end
        end
      end
    end
  end

  describe '/export' do
    before { Sinatra::Base.set :export, enabled: true }

    describe '/services' do
      it_behaves_like 'export API'

      context 'valid request' do
        before(:each) do
          enableexampleservice
        end

        it '200' do
          get '/export/services', nil, 'HTTP_AUTHORIZATION' => 'AAF-RAPID-EXPORT service="test", key="test_secret"'
          expect(last_response.status).to eq 200
        end

        it 'provides json' do
          get '/export/services', nil, 'HTTP_AUTHORIZATION' => 'AAF-RAPID-EXPORT service="test", key="test_secret"'
          json = JSON.parse(response.body)
          expect(json['services'][0]['id']).to eq '1234abcd'
          expect(json['services'][0]['rapidconnect']['secret']).to eq 'ykUlP1XMq3RXMd9w'
        end
      end
    end

    describe '/service/:identifier' do
      it_behaves_like 'export API'

      context 'invalid service' do
        it '404' do
          get '/export/services/notvalid', nil, 'HTTP_AUTHORIZATION' => 'AAF-RAPID-EXPORT service="test", key="test_secret"'
          expect(last_response.status).to eq 404
        end
      end

      context 'valid service' do
        before(:each) do
          enableexampleservice
        end
        it '200' do
          get '/export/service/1234abcd', nil, 'HTTP_AUTHORIZATION' => 'AAF-RAPID-EXPORT service="test", key="test_secret"'
          expect(last_response.status).to eq 200
        end
        it 'provides json' do
          get '/export/service/1234abcd', nil, 'HTTP_AUTHORIZATION' => 'AAF-RAPID-EXPORT service="test", key="test_secret"'
          json = JSON.parse(response.body)
          expect(json['service']['id']).to eq '1234abcd'
          expect(json['service']['rapidconnect']['secret']).to eq 'ykUlP1XMq3RXMd9w'
        end
      end
    end
  end
end
