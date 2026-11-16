# frozen_string_literal: true

RSpec.describe SayWhen do
  let(:reader) { SayWhen::Reader.new }
  let(:today) { Date.new(2026, 10, 20) }

  it "has a version number" do
    expect(SayWhen::VERSION).not_to be_nil
  end

  describe "#days" do
    it "reads a day, and how it was read" do
      read = reader.days("the day before the last working day of november", today: today)

      expect(read.first.day).to eq(Date.new(2026, 11, 29))
      expect(read.first.how).to eq("the day before Mon 30 Nov, the last working day of November 2026")
    end

    it "gives every reading of an ambiguous phrase" do
      read = SayWhen::Reader.new(locale: :canada).days("3/4", today: today)

      expect(read.map(&:day)).to contain_exactly(Date.new(2027, 4, 3), Date.new(2027, 3, 4))
    end

    it "is empty for something that isn't a day" do
      expect(reader.days("lunch with priya", today: today)).to eq([])
      expect(reader.day("lunch with priya", today: today)).to be_nil
    end

    it "accepts ISO strings and Times for days" do
      expect(reader.day("tomorrow", today: "2026-10-20")).to eq(Date.new(2026, 10, 21))
      expect(reader.day("tomorrow", today: Time.new(2026, 10, 20, 23, 0))).to eq(Date.new(2026, 10, 21))
    end
  end

  describe "#span" do
    it "reads a span of days" do
      span = reader.span("november", today: today)

      expect(span.first).to eq(Date.new(2026, 11, 1))
      expect(span.last).to eq(Date.new(2026, 11, 30))
      expect(span.kind).to eq(:month)
      expect(span.to_range).to cover(Date.new(2026, 11, 15))
    end

    it "is nil for something that isn't a span" do
      expect(reader.span("lunch", today: today)).to be_nil
    end
  end

  describe "#suggest_days" do
    it "suggests days as they're typed" do
      names = reader.suggest_days("t", today: Date.new(2026, 11, 20)).map(&:name) # a Friday

      expect(names).to include("Tomorrow", "Tuesday", "Thursday")
    end
  end

  describe "repeats" do
    let(:reading) { reader.repeats("every other thursday until christmas", from: today, today: today).first }

    it "reads how something repeats as an RRULE" do
      expect(reading.repeat.rule).to eq("FREQ=WEEKLY;INTERVAL=2;BYDAY=TH;UNTIL=20261225")
      expect(reading.repeat.kind).to eq(:schedule)
      expect(reading.repeat).to be_schedule
      expect(reading.how).to eq("Every 2 weeks on Thursday, until 25 December")
      expect(reading.next_days.first).to eq(Date.new(2026, 10, 22))
    end

    it "round-trips a repeat back into the reader" do
      repeat = reading.repeat

      expect(reader.describe_repeat(repeat, today: today)).to eq(reading.how)
      expect(reader.next_days(repeat, limit: 2)).to eq([Date.new(2026, 10, 22), Date.new(2026, 11, 5)])
      expect(reader.repeats_on?(repeat, Date.new(2026, 11, 5))).to be(true)
      expect(reader.repeats_on?(repeat, Date.new(2026, 11, 12))).to be(false)
      expect(reader.last_repeat_day(repeat)).to eq(Date.new(2026, 12, 17))
      expect(reader.repeat_days(repeat, from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30)))
        .to eq([Date.new(2026, 11, 5), Date.new(2026, 11, 19)])
    end

    it "takes a repeat built by hand" do
      repeat = SayWhen::Repeat.new(kind: :schedule, rule: "FREQ=WEEKLY;BYDAY=MO", starts: "2026-11-16")

      expect(reader.next_days(repeat, limit: 2)).to eq([Date.new(2026, 11, 16), Date.new(2026, 11, 23)])
      expect(reader.last_repeat_day(repeat)).to be_nil
    end

    it "raises ArgumentError for a rule it can't work out" do
      repeat = SayWhen::Repeat.new(kind: :schedule, rule: "nonsense", starts: today)

      expect { reader.next_days(repeat) }.to raise_error(ArgumentError, /invalid repeat/)
    end

    it "suggests repeats" do
      expect(reader.suggest_repeats(from: today, today: today).map(&:how)).to include("Every day")
    end
  end

  describe "times" do
    it "reads a time of day" do
      expect(reader.time("half three")).to eq(SayWhen::ClockTime.new(hour: 15, minute: 30))
      expect(reader.time("13:30").to_s).to eq("13:30")
      expect(SayWhen.read_clock("noon")).to eq(SayWhen::ClockTime.parse("12:00"))
      expect(reader.time("banana")).to be_nil
    end
  end

  describe "offsets" do
    it "reads an offset and lands it from an event" do
      offset = reader.offset("the day before at 9am")
      expect(offset).to eq("-P1D@09:00")

      day, time = reader.offset_from(offset, Date.new(2026, 12, 3), "14:00")
      expect(day).to eq(Date.new(2026, 12, 2))
      expect(time).to eq(SayWhen::ClockTime.new(hour: 9, minute: 0))
    end

    it "is nil for an offset that doesn't say which way" do
      expect(reader.offset("3 days")).to be_nil
    end

    it "raises for a malformed offset" do
      expect { reader.offset_from("garbage", today) }.to raise_error(ArgumentError, /not an offset/)
    end
  end

  describe "#event" do
    it "reads an event's sentence word by word" do
      text = "Lunch tomorrow 1-2pm at Dishoom"
      event = reader.event(text, today: Date.new(2026, 11, 16), fallback_time: "09:00")

      expect(event.title).to eq("Lunch")
      expect(event.start_day).to eq(Date.new(2026, 11, 17))
      expect([event.start_time.to_s, event.end_time.to_s]).to eq(%w[13:00 14:00])
      expect(event.location).to eq("Dishoom")
      expect(event).not_to be_all_day
      expect(event.words.map { [_1.text(text), _1.role] }).to eq([
        ["Lunch", :title], ["tomorrow", :day], ["1-2pm", :time], ["at", :place], ["Dishoom", :place]
      ])
    end

    it "reads how an event repeats" do
      event = reader.event("Standup every weekday at 9:30 for 15 mins", today: Date.new(2026, 11, 16))

      expect(event.repeat.how).to eq("Every weekday")
      expect(event.repeat.repeat.rule).to eq("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
      expect(event.read).to be_length
      expect(reader.next_days(event.repeat, limit: 2)).to eq([Date.new(2026, 11, 16), Date.new(2026, 11, 17)])
    end

    it "reads mentions" do
      text = "Lunch with #Priya tomorrow"
      event = reader.event(text, today: Date.new(2026, 11, 16), mentions: { "#Priya" => "Priya" })

      expect(event.mentioned).to eq([0])
      mention = event.words.find { _1.role == :mention }
      expect(mention.mention).to eq(0)
      expect(mention.text(text)).to eq("#Priya")
    end

    it "slices words by byte offsets in non-ASCII text" do
      text = "Café with Zoë tomorrow at 1"
      event = reader.event(text, today: Date.new(2026, 11, 16))

      expect(event.words.find { _1.role == :day }.text(text)).to eq("tomorrow")
      expect(event.title).to eq("Café with Zoë")
    end
  end

  describe "#when" do
    it "reads when something is" do
      found = reader.when("fri 6pm to sun 5pm", today: Date.new(2026, 11, 16))

      expect([found.start_day, found.start_time.to_s]).to eq([Date.new(2026, 11, 20), "18:00"])
      expect([found.end_day, found.end_time.to_s]).to eq([Date.new(2026, 11, 22), "17:00"])
    end

    it "is nil when anything typed isn't when" do
      expect(reader.when("lunch tomorrow", today: today)).to be_nil
    end
  end

  describe "calendars" do
    let(:reader) do
      SayWhen::Reader.new(
        locale: :us,
        calendar: {
          days_off: [{ day: Date.new(2026, 11, 26), name: "Thanksgiving" }],
          named_days: [{ day: SayWhen.easter(2027), names: ["Easter Sunday", "Easter"] }]
        }
      )
    end

    it "counts working days around days off" do
      read = reader.days("2 working days after 11/25", today: today)

      expect(read.first.day).to eq(Date.new(2026, 11, 30))
      expect(read.first.how).to eq("2 working days after Wed, Nov 25")
      expect(reader.working_day?(Date.new(2026, 11, 26))).to be(false)
    end

    it "reads named days" do
      expect(reader.day("a week before easter", today: today)).to eq(Date.new(2027, 3, 21))
    end

    it "takes a working week" do
      reader = SayWhen::Reader.new(calendar: { working_week: %i[sunday monday tuesday wednesday thursday] })

      expect(reader.working_day?(Date.new(2026, 11, 20))).to be(false) # a Friday
    end
  end

  describe "named dates" do
    let(:reader) do
      SayWhen::Reader.new(named_dates: [{ names: ["eli", "eli jones"], what: ["birthday"], month: 3, day: 14, label: "Eli Jones’s birthday" }])
    end

    it "reads days by names only the caller knows" do
      read = reader.days("2 weeks before eli's birthday", today: today).first

      expect(read.day).to eq(Date.new(2027, 2, 28))
      expect(read.about).to eq("2 weeks before Eli Jones’s birthday")
    end

    it "reads pronouns as whoever a text is about" do
      expect(reader.days("his birthday", today: today)).to eq([])
      expect(reader.about("Plan Eli's party").day("his birthday", today: today)).to eq(Date.new(2027, 3, 14))
    end
  end

  describe "zones" do
    it "reads which time zone an event is in" do
      reader = SayWhen::Reader.new(zones: { before_word_time: { "New  York" => "America/New_York" } })
      event = reader.event("Call at 9am New York time", today: Date.new(2026, 11, 16))

      expect(event.time_zone).to eq("America/New_York")
    end
  end

  describe "#corrected" do
    it "puts words one letter off right" do
      expect(reader.corrected("tmorrow")).to eq("tomorrow")
      expect(reader.corrected("tomorrow")).to be_nil
    end
  end

  describe "locales" do
    it "builds a reader for every locale" do
      SayWhen::LOCALES.each do |locale|
        expect(SayWhen::Reader.new(locale:).day("tomorrow", today: today)).to eq(Date.new(2026, 10, 21))
      end
    end

    it "reads dates in figures by locale" do
      expect(SayWhen::Reader.new(locale: :new_zealand).day("3/4", today: today)).to eq(Date.new(2027, 4, 3))
      expect(SayWhen::Reader.new(locale: :us).day("3/4", today: today)).to eq(Date.new(2027, 3, 4))
    end
  end

  describe "bad input" do
    it "rejects unknown locales" do
      expect { SayWhen::Reader.new(locale: :mars) }.to raise_error(ArgumentError, /unknown locale/)
    end

    it "rejects bad dates" do
      expect { reader.days("tomorrow", today: "not a date") }.to raise_error(ArgumentError)
    end

    it "rejects missing named date fields" do
      expect { SayWhen::Reader.new(named_dates: [{ names: ["x"] }]) }.to raise_error(ArgumentError, /missing :month/)
    end
  end
end
