describe Insights::API::Common::RBAC::Service do
  let(:rbac_none_zero_ex) { RBACApiClient::ApiError.new(:messsage => "kaboom", :code => 1) }
  let(:rbac_zero_ex) { RBACApiClient::ApiError.new(:messsage => "kaboom", :code => 0) }
  let(:rbac_nil_ex) { RBACApiClient::ApiError.new(:messsage => "kaboom") }
  let(:page_size) { 3 }
  let(:page1_data) { [1, 2, 3] }
  let(:page2_data) { [4, 5, 6] }
  let(:page1_args) { { :limit => page_size, :offset => 0 } }
  let(:page2_args) { { :limit => page_size, :offset => 3 } }
  let(:meta) { double('count' => 6) }
  let(:result1) { double(:meta => meta, :data => page1_data) }
  let(:result2) { double(:meta => meta, :data => page2_data) }
  let(:obj) { double }

  it "raises RBACApiClient::ApiError" do
    allow(Insights::API::Common::Request).to receive(:current_forwardable).and_return(:x => 1)

    expect do
      stub_const("ENV", "RBAC_URL" => 'http://www.example.com')
      described_class.call(RBACApiClient::StatusApi) do |_klass|
        raise rbac_none_zero_ex
      end
    end.to raise_exception(RBACApiClient::ApiError)

    expect do
      stub_const("ENV", "RBAC_URL" => 'http://www.example.com')
      described_class.call(RBACApiClient::StatusApi) do |_klass|
        raise rbac_zero_ex
      end
    end.to raise_exception(Insights::API::Common::RBAC::NetworkError)

    expect do
      stub_const("ENV", "RBAC_URL" => 'http://www.example.com')
      described_class.call(RBACApiClient::StatusApi) do |_klass|
        raise rbac_nil_ex
      end
    end.to raise_exception(Insights::API::Common::RBAC::TimedOutError)
  end

  context "pagination" do
    it "paginates" do
      allow(obj).to receive(:dummy).with(page1_args).and_return(result1)
      allow(obj).to receive(:dummy).with(page2_args).and_return(result2)
      expect(described_class.paginate(obj, :dummy, :limit => page_size).to_a.size).to eq(6)
    end

    it "paginates with extra_args" do
      allow(obj).to receive(:dummy).with("extra_arg", page1_args).and_return(result1)
      allow(obj).to receive(:dummy).with("extra_arg", page2_args).and_return(result2)
      expect(described_class.paginate(obj, :dummy, { :limit => 3 }, "extra_arg").to_a.size).to eq(6)
    end

    it "handles exception" do
      allow(obj).to receive(:dummy).with(page1_args).and_raise(StandardError.new("kaboom"))
      expect do
        described_class.paginate(obj, :dummy, :limit => 3).to_a
      end.to raise_exception(StandardError)
    end
  end

  context "user headers" do
    it 'includes user headers in default headers' do
      stub_const("ENV", "RBAC_URL" => 'http://www.example.com')
      allow(Insights::API::Common::Request).to receive(:current_forwardable).and_return(:x => 1)
      described_class.call(RBACApiClient::StatusApi, 'x-rh-user-header' => 'value') do |api|
        expect(api.api_client.default_headers).to include(:x => 1, 'x-rh-user-header' => 'value')
      end
    end
  end
end
