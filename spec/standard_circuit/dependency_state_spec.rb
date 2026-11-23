require "spec_helper"

# open? / status / circuits and the lock API on StandardCircuit.dependency.
RSpec.describe StandardCircuit::Dependency do
  def fail_once(name, purpose: nil)
    StandardCircuit.run(name, purpose: purpose) { raise "boom" }
  rescue RuntimeError, Stoplight::Error::RedLight
    nil
  end

  def dependency(name) = StandardCircuit.dependency(name)

  describe "a one-breaker dependency" do
    before do
      StandardCircuit.configure do |c|
        c.register(:myinfo, threshold: 1, criticality: :critical, tracked_errors: [ RuntimeError ])
      end
    end

    it "is not open and :ok before anything fails" do
      expect(dependency(:myinfo)).to have_attributes(open?: false, status: :ok)
    end

    it "is open and :unavailable once its breaker trips" do
      fail_once(:myinfo)

      expect(dependency(:myinfo)).to have_attributes(open?: true, status: :unavailable)
      expect(dependency(:myinfo).purpose(:default)).to have_attributes(open?: true, color: "red")
    end

    it "counts force_open as open and force_closed as closed" do
      StandardCircuit.force_open(:myinfo) { expect(dependency(:myinfo).open?).to be(true) }

      fail_once(:myinfo)
      StandardCircuit.force_closed(:myinfo) do
        expect(dependency(:myinfo)).to have_attributes(open?: false, status: :ok)
      end
    end

    it "reports its circuits with color, lock and forced state" do
      StandardCircuit.force_open(:myinfo) do
        expect(dependency(:myinfo).circuits).to eq([ { name: :myinfo, color: "green", locked: false, forced: :open } ])
      end
    end

    it "does not count half-open (yellow) as open" do
      allow(StandardCircuit.runner).to receive(:circuit_state)
        .and_return(name: :myinfo, color: "yellow", locked: false, forced: nil)

      expect(dependency(:myinfo)).to have_attributes(open?: false, status: :degraded)
    end
  end

  describe "status by criticality" do
    {
      critical: :unavailable,
      standard: :degraded,
      optional: :ok
    }.each do |criticality, expected|
      it "is #{expected} for a red #{criticality} breaker" do
        StandardCircuit.configure { |c| c.register(:dep, criticality: criticality) }
        dependency(:dep).lock_open!

        expect(dependency(:dep).status).to eq(expected)
      end
    end
  end

  describe "purposes sharing a breaker" do
    before do
      StandardCircuit.configure do |c|
        c.dependency :google_oauth, threshold: 1, tracked_errors: [ RuntimeError ] do |d|
          d.purpose :sign_in, criticality: :critical
          d.purpose :calendar, criticality: :standard
        end
      end
    end

    it "takes the worst affected purpose as the dependency's status" do
      fail_once(:google_oauth, purpose: :calendar)
      dep = dependency(:google_oauth)

      expect(dep.purposes.to_h { |p| [ p.name, p.status ] }).to eq(sign_in: :unavailable, calendar: :degraded)
      expect(dep).to have_attributes(status: :unavailable, open?: true)
    end

    it "locks the shared breaker for every purpose through any one of them" do
      dependency(:google_oauth).purpose(:calendar).lock_open!

      expect { StandardCircuit.run(:google_oauth, purpose: :sign_in) { :ok } }
        .to raise_error(Stoplight::Error::RedLight)
    end
  end

  describe "an isolated purpose" do
    before do
      StandardCircuit.configure do |c|
        c.dependency :google_maps, criticality: :standard, tracked_errors: [ RuntimeError ] do |d|
          d.purpose :places, default: true
          d.purpose :address, isolate: true, threshold: 1
        end
      end
    end

    it "opens on its own without opening the dependency" do
      fail_once(:google_maps, purpose: :address)
      dep = dependency(:google_maps)

      expect(dep.purpose(:address)).to have_attributes(open?: true, status: :degraded)
      expect(dep.purpose(:places)).to have_attributes(open?: false, status: :ok)
      expect(dep).to have_attributes(open?: false, status: :degraded)
    end

    it "locks only its own breaker" do
      dependency(:google_maps).purpose(:address).lock_open!

      expect { StandardCircuit.run(:google_maps, purpose: :address) { :ok } }.to raise_error(Stoplight::Error::RedLight)
      expect(StandardCircuit.run(:google_maps, purpose: :places) { :ok }).to eq(:ok)
    end

    it "is open as a dependency only when every purpose is" do
      dependency(:google_maps).lock_open!

      expect(dependency(:google_maps).open?).to be(true)
    end
  end

  describe "the lock API" do
    before do
      StandardCircuit.configure do |c|
        c.register(:stripe, threshold: 1, criticality: :critical, tracked_errors: [ RuntimeError ])
      end
    end

    it "lock_open! blocks calls until unlock!" do
      dependency(:stripe).lock_open!
      expect { StandardCircuit.run(:stripe) { :ok } }.to raise_error(Stoplight::Error::RedLight)
      expect(StandardCircuit.run(:stripe, fallback: -> { :fallback }) { :ok }).to eq(:fallback)

      dependency(:stripe).unlock!
      expect(StandardCircuit.run(:stripe) { :ok }).to eq(:ok)
    end

    it "lock_closed! keeps the breaker closed through failures" do
      dependency(:stripe).lock_closed!
      2.times { fail_once(:stripe) }

      expect(dependency(:stripe)).to have_attributes(open?: false, status: :ok)
      expect(dependency(:stripe).circuits.first).to include(color: "green", locked: true)
    end

    it "returns the handle, so calls chain" do
      dep = dependency(:stripe)

      expect(dep.lock_open!).to be(dep)
      expect(dep.unlock!.lock_closed!.unlock!).to be(dep)
    end

    # The supported replacement for `runner.light_for(:x).lock(Stoplight::Color::RED)`.
    it "leaves health_report exactly as the light-level lock did" do
      StandardCircuit.runner.light_for(:stripe).lock(Stoplight::Color::RED)
      via_light = StandardCircuit.health_report
      StandardCircuit.reset!

      dependency(:stripe).lock_open!

      expect(StandardCircuit.health_report).to eq(via_light)
    end

    it "is cleared by reset! with the default Memory store" do
      dependency(:stripe).lock_open!
      StandardCircuit.reset!

      expect(dependency(:stripe).open?).to be(false)
    end
  end

  describe "a prefix dependency" do
    before do
      StandardCircuit.configure do |c|
        c.register_prefix(:s3, threshold: 1, criticality: :standard, tracked_errors: [ RuntimeError ])
      end
    end

    it "is neither open nor degraded before any sub-circuit is used" do
      expect(dependency(:s3)).to have_attributes(open?: false, status: :ok, circuits: [])
    end

    it "is degraded, not open, while only some sub-circuits are open" do
      fail_once(:s3_uploads)
      StandardCircuit.run(:s3_avatars) { :ok }

      expect(dependency(:s3)).to have_attributes(open?: false, status: :degraded)
    end

    it "locks every sub-circuit used so far" do
      StandardCircuit.run(:s3_uploads) { :ok }
      StandardCircuit.run(:s3_avatars) { :ok }

      dependency(:s3).lock_open!

      expect(dependency(:s3).circuits.map { |c| c.slice(:name, :locked) })
        .to contain_exactly({ name: :s3_uploads, locked: true }, { name: :s3_avatars, locked: true })
      expect(dependency(:s3).open?).to be(true)
    end
  end
end
