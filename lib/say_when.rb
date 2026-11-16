# frozen_string_literal: true

require "date"
require_relative "say_when/version"
begin
  # Precompiled native gems ship one library per Ruby minor version.
  require "say_when/#{RUBY_VERSION[/\d+\.\d+/]}/say_when"
rescue LoadError
  # Source installs compile a single library.
  require "say_when/say_when"
end

# Ruby bindings for the say-when Rust crate (https://crates.io/crates/say-when):
# reads days, spans of days, times and how things repeat, written in plain
# English.
#
#   reader = SayWhen::Reader.new(locale: :uk)
#   reader.days("next fri", today: Date.new(2026, 11, 16)).first.day
#   # => #<Date: 2026-11-20>
module SayWhen
  class Error < StandardError; end

  LOCALES = %i[uk us ireland australia new_zealand canada].freeze
  WEEKDAYS = %i[monday tuesday wednesday thursday friday saturday sunday].freeze

  # A time of day, with no date or zone: what the crate calls a Time.
  ClockTime = Data.define(:hour, :minute) do
    include Comparable

    def self.parse(text)
      match = /\A(\d{1,2}):(\d{2})\z/.match(text.to_s) or raise ArgumentError, "not a time written HH:MM: #{text.inspect}"
      new(hour: match[1].to_i, minute: match[2].to_i)
    end

    # Accepts a ClockTime, an "HH:MM" string, or anything with #hour and #min (Time, DateTime).
    def self.coerce(value)
      case value
      when ClockTime then value
      when String then parse(value)
      else
        return new(hour: value.hour, minute: value.min) if value.respond_to?(:hour) && value.respond_to?(:min)

        raise ArgumentError, "can't read #{value.inspect} as a time of day"
      end
    end

    def <=>(other) = other.is_a?(ClockTime) ? to_a <=> other.to_a : nil
    def to_a = [hour, minute]
    def to_s = format("%02d:%02d", hour, minute)
    def inspect = "#<SayWhen::ClockTime #{self}>"
  end

  # A day a phrase might mean.
  DayReading = Data.define(:day, :how, :about)

  # A span of days a phrase names. +kind+ is one of :week, :weekend, :month, :quarter, :year, :named.
  SpanReading = Data.define(:first, :last, :kind) do
    def to_range = first..last
  end

  # A day what's typed in a date picker's search might mean.
  DaySuggestion = Data.define(:day, :name, :about)

  # How something repeats. +kind+ is :schedule or :after (so long after it's done);
  # +rule+ is an iCalendar RRULE string; +skipped+ are EXDATE-style days.
  Repeat = Data.define(:kind, :rule, :starts, :skipped) do
    def initialize(kind:, rule:, starts:, skipped: [])
      super(kind: kind.to_sym, rule: rule.to_s, starts: SayWhen.date(starts), skipped: skipped.map { SayWhen.date(_1) })
    end

    def schedule? = kind == :schedule
    def after_done? = kind == :after
    def to_s = rule

    # The crate's serde shape.
    def to_native
      { "kind" => kind.to_s, "rule" => rule, "starts" => starts.iso8601, "skipped" => skipped.map(&:iso8601) }
    end
  end

  # A way a phrase might say something repeats, with the next few days it comes round on.
  RepeatReading = Data.define(:repeat, :how, :next_days)

  # How an event repeats, and how that was read.
  EventRepeat = Data.define(:repeat, :how)

  # What of an event was read from what was typed rather than assumed.
  # +meal+ is the meal its time was taken from (:breakfast, :brunch, :lunch, :drinks, :dinner), if any.
  EventRead = Data.define(:day, :time, :length, :meal) do
    alias_method :day?, :day
    alias_method :time?, :time
    alias_method :length?, :length
  end

  # A word of what was typed and what it was read as. +start+ and +end+ are
  # *byte* offsets; use #text to slice the source. +role+ is one of :title,
  # :mention, :day, :time, :length, :repeat, :time_zone, :place; for :mention,
  # +mention+ is its index among the mentions given.
  ReadWord = Data.define(:start, :end, :role, :mention) do
    def text(source) = source.byteslice(start...self.end).force_encoding(source.encoding)
  end

  # Someone mentioned in an event's sentence: +written+ as it appears ("#Priya"), +said+ as the title says it.
  Mention = Data.define(:written, :said)

  # An event, as its sentence says it.
  EventReading = Data.define(
    :title, :mentioned, :start_day, :end_day, :start_time, :end_time,
    :location, :repeat, :time_zone, :read, :others, :words
  ) do
    def all_day? = start_time.nil?
  end

  # When something is, said with nothing else.
  WhenReading = Data.define(:start_day, :end_day, :start_time, :end_time, :time_zone, :others, :words) do
    def all_day? = start_time.nil?
  end

  class << self
    # Easter Sunday in a year.
    def easter(year) = date(_easter(Integer(year)))

    # A time of day typed on its own: "3pm", "13:30", "half three", "noon".
    # A bare hour is in the afternoon up to 7, or the first after +after+.
    def read_clock(text, after: nil)
      clock(_read_clock(text.to_s, after && ClockTime.coerce(after).to_s))
    end

    # @api private
    def date(value)
      case value
      when nil then nil
      when Date then value.is_a?(DateTime) ? value.to_date : value
      when String then Date.iso8601(value)
      else
        return value.to_date if value.respond_to?(:to_date)

        raise ArgumentError, "can't read #{value.inspect} as a date"
      end
    rescue Date::Error
      raise ArgumentError, "not a date written YYYY-MM-DD: #{value.inspect}"
    end

    # @api private
    def iso(value) = date(value).iso8601

    # @api private
    def clock(value) = value && ClockTime.parse(value)
  end

  private_class_method :_easter, :_read_clock
  private_constant :Native

  # Reads what's typed, for somewhere and someone. Build one and keep it: it
  # works out what it's told once. Readers are immutable and safe to share.
  class Reader
    # locale:: one of SayWhen::LOCALES (:uk unless said).
    # calendar:: days off, named days and the working week:
    #   { days_off: [Date | { day: Date, name: "Thanksgiving" }],
    #     named_days: [{ day: Date, last: Date (optional), names: ["Easter Sunday", "Easter"] }],
    #     working_week: %i[monday tuesday wednesday thursday friday] }
    # named_dates:: days only the caller knows by name, like birthdays:
    #   [{ names: ["mum"], what: ["birthday"], month: 3, day: 14, label: "Mum's birthday" }]
    # zones:: names time zones go by (matched case-insensitively), mapped to whatever they stand for:
    #   { before_word_time: { "new york" => "America/New_York" }, after_a_time: { "pt" => "America/Los_Angeles" } }
    def initialize(locale: :uk, calendar: nil, named_dates: [], zones: nil, native: nil)
      @native = native || Native.new(
        "options" => { "locale" => locale_name(locale) },
        "calendar" => calendar && native_calendar(calendar),
        "named_dates" => named_dates.map { native_named_date(_1) },
        "zones" => zones && native_zones(zones)
      )
      freeze
    end

    # A reader that also reads "his", "her" and "their" as whoever +text+ names
    # (like the title of the thing a day's being picked for).
    def about(text) = self.class.new(native: @native.about(text.to_s))

    # Whether a day is worked, by this reader's calendar.
    def working_day?(date) = @native.working_day?(SayWhen.iso(date))

    # Every day a phrase might mean, the likeliest first. Empty when it isn't a day.
    def days(text, today: Date.today)
      @native.days(text.to_s, SayWhen.iso(today)).map { day_reading(_1) }
    end

    # The likeliest day a phrase means, or nil.
    def day(text, today: Date.today) = days(text, today:).first&.day

    # The span of days a phrase names ("next week", "november", "q3 2027"), or nil.
    def span(text, today: Date.today)
      found = @native.span(text.to_s, SayWhen.iso(today)) or return nil
      SpanReading.new(first: SayWhen.date(found[:first]), last: SayWhen.date(found[:last]), kind: found[:kind].to_sym)
    end

    # The days a date picker's search might mean as it's typed, never before today.
    def suggest_days(typed, today: Date.today)
      @native.suggest_days(typed.to_s, SayWhen.iso(today)).map do |found|
        DaySuggestion.new(day: SayWhen.date(found[:day]), name: found[:name], about: found[:about])
      end
    end

    # Every way a phrase might say something repeats. +from+ is the day the
    # thing is on now, which "every week" and "monthly" take their days from.
    def repeats(text, from: Date.today, today: Date.today)
      @native.repeats(text.to_s, SayWhen.iso(from), SayWhen.iso(today)).map { repeat_reading(_1) }
    end

    # What a repeat picker offers before anything's typed.
    def suggest_repeats(from: Date.today, today: Date.today)
      @native.suggest_repeats(SayWhen.iso(from), SayWhen.iso(today)).map { repeat_reading(_1) }
    end

    # How a repeat is said, like "Every 2 weeks on Tuesday". The year of +today+ is left off the day it ends.
    def describe_repeat(repeat, today: nil)
      @native.describe_repeat(native_repeat(repeat), today && SayWhen.iso(today))
    end

    # The next +limit+ days a repeat comes round on, from a day on.
    def next_days(repeat, from: nil, limit: 4)
      repeat = coerce_repeat(repeat)
      @native.next_days(repeat.to_native, SayWhen.iso(from || repeat.starts), Integer(limit)).map { SayWhen.date(_1) }
    end

    # Each day a scheduled repeat comes round on between two days, both included.
    def repeat_days(repeat, from:, to:)
      @native.repeat_days(native_repeat(repeat), SayWhen.iso(from), SayWhen.iso(to)).map { SayWhen.date(_1) }
    end

    # Whether a scheduled repeat comes round on a day.
    def repeats_on?(repeat, date) = @native.repeats_on?(native_repeat(repeat), SayWhen.iso(date))

    # The last day a scheduled repeat comes round on, if it stops; else nil.
    def last_repeat_day(repeat) = SayWhen.date(@native.last_repeat_day(native_repeat(repeat)))

    # A time of day typed on its own: "3pm", "13:30", "half three", "noon".
    def time(text, after: nil)
      SayWhen.clock(@native.time(text.to_s, after && ClockTime.coerce(after).to_s))
    end

    # Where something is from a day, like a reminder from its event: "3 days
    # before", "the day before at 9am". Returns the offset in the crate's
    # string form (e.g. "-P1D@09:00"), which #offset_from takes back; nil if
    # it isn't one.
    def offset(text) = @native.offset(text.to_s)

    # Where an offset lands from a day (and time, if the event has one):
    # [Date, ClockTime or nil], or nil when it lands nowhere.
    def offset_from(offset, date, time = nil)
      day, at = @native.offset_from(offset.to_s, SayWhen.iso(date), time && ClockTime.coerce(time).to_s)
      day && [SayWhen.date(day), SayWhen.clock(at)]
    end

    # Reads an event typed as a sentence, like "Lunch with Priya tomorrow at 1 at Monmouth".
    #
    # mentions:: who may be mentioned, in order: [Mention | { written:, said: }] or { "#Priya" => "Priya" }.
    def event(text, today: Date.today, fallback_day: nil, fallback_time: "09:00", default_length: 60, mentions: [])
      context = {
        "today" => SayWhen.iso(today),
        "fallback_day" => SayWhen.iso(fallback_day || today),
        "fallback_time" => ClockTime.coerce(fallback_time).to_s,
        "default_length" => Integer(default_length),
        "mentions" => native_mentions(mentions)
      }
      event_reading(@native.event(text.to_s, context))
    end

    # When something is, typed with nothing else ("tomorrow 2-4pm", "fri 6pm
    # to sun 5pm"); nil when anything typed isn't when.
    def when(text, today: Date.today)
      found = @native.when(text.to_s, SayWhen.iso(today)) or return nil
      WhenReading.new(
        start_day: SayWhen.date(found[:start_day]), end_day: SayWhen.date(found[:end_day]),
        start_time: SayWhen.clock(found[:start_time]), end_time: SayWhen.clock(found[:end_time]),
        time_zone: found[:time_zone], others: found[:others].map { SayWhen.date(_1) },
        words: found[:words].map { read_word(_1) }
      )
    end

    # What's typed with each word one letter off a date word put right
    # ("tmorrow" => "tomorrow"), or nil when no word is. Words in +more+ are put right too.
    def corrected(typed, more: []) = @native.corrected(typed.to_s, more.map(&:to_s))

    def inspect = "#<#{self.class.name}>"

    private

    def locale_name(locale)
      locale = locale.to_s.downcase.tr("-", "_").to_sym
      raise ArgumentError, "unknown locale #{locale.inspect}; one of #{LOCALES.inspect}" unless LOCALES.include?(locale)

      locale.to_s.tr("_", "-")
    end

    def native_calendar(calendar)
      calendar = calendar.transform_keys(&:to_sym)
      out = {}
      out["days_off"] = calendar.fetch(:days_off, []).map do |off|
        off.is_a?(Hash) ? { "day" => SayWhen.iso(fetch(off, :day)), "name" => fetch(off, :name, nil)&.to_s } : { "day" => SayWhen.iso(off) }
      end
      out["named_days"] = calendar.fetch(:named_days, []).map do |named|
        last = fetch(named, :last, nil)
        { "day" => SayWhen.iso(fetch(named, :day)), "last" => last && SayWhen.iso(last), "names" => Array(fetch(named, :names)).map(&:to_s) }
      end
      if calendar.key?(:working_week)
        out["working_week"] = calendar[:working_week].map do |weekday|
          weekday = weekday.to_s.downcase.to_sym
          raise ArgumentError, "unknown weekday #{weekday.inspect}" unless WEEKDAYS.include?(weekday)

          weekday.to_s
        end
      end
      out
    end

    def native_named_date(date)
      {
        "names" => Array(fetch(date, :names, [])).map(&:to_s),
        "what" => Array(fetch(date, :what, [])).map(&:to_s),
        "month" => Integer(fetch(date, :month)),
        "day" => Integer(fetch(date, :day)),
        "label" => fetch(date, :label, nil)&.to_s
      }
    end

    def native_zones(zones)
      zones = zones.transform_keys(&:to_sym)
      %i[before_word_time after_a_time].to_h do |key|
        [key.to_s, zones.fetch(key, {}).map { |name, zone| [name.to_s.downcase.split.join(" "), zone.to_s] }]
      end
    end

    def native_mentions(mentions)
      mentions = mentions.map { |written, said| Mention.new(written:, said:) } if mentions.is_a?(Hash)
      mentions.map do |mention|
        { "written" => fetch(mention, :written).to_s, "said" => fetch(mention, :said).to_s }
      end
    end

    def fetch(object, key, *default)
      return object.public_send(key) if object.is_a?(Data) && object.respond_to?(key)
      return object.fetch(key) { object.fetch(key.to_s, *default) } if object.is_a?(Hash)

      raise ArgumentError, "expected a Hash, got #{object.inspect}"
    rescue KeyError
      raise ArgumentError, "missing #{key.inspect} in #{object.inspect}"
    end

    def coerce_repeat(repeat)
      case repeat
      when Repeat then repeat
      when RepeatReading, EventRepeat then repeat.repeat
      when Hash then Repeat.new(**repeat.transform_keys(&:to_sym).slice(:kind, :rule, :starts, :skipped))
      else raise ArgumentError, "expected a SayWhen::Repeat, got #{repeat.inspect}"
      end
    end

    def native_repeat(repeat) = coerce_repeat(repeat).to_native

    def day_reading(found)
      DayReading.new(day: SayWhen.date(found[:day]), how: found[:how], about: found[:about])
    end

    def repeat_from(found)
      found = found.transform_keys(&:to_sym) # flattened serde maps come back with string keys
      Repeat.new(kind: found[:kind], rule: found[:rule], starts: found[:starts], skipped: found[:skipped] || [])
    end

    def repeat_reading(found)
      RepeatReading.new(repeat: repeat_from(found[:repeat]), how: found[:how], next_days: found[:next].map { SayWhen.date(_1) })
    end

    def read_word(found)
      role = found[:role]
      if role.is_a?(Hash) # { mention: index }
        key, index = role.first
        ReadWord.new(start: found[:start], end: found[:end], role: key.to_sym, mention: index)
      else
        ReadWord.new(start: found[:start], end: found[:end], role: role.to_sym, mention: nil)
      end
    end

    def event_reading(found)
      read = found[:read]
      repeat = found[:repeat]&.transform_keys(&:to_sym)
      EventReading.new(
        title: found[:title], mentioned: found[:mentioned],
        start_day: SayWhen.date(found[:start_day]), end_day: SayWhen.date(found[:end_day]),
        start_time: SayWhen.clock(found[:start_time]), end_time: SayWhen.clock(found[:end_time]),
        location: found[:location],
        repeat: repeat && EventRepeat.new(repeat: repeat_from(repeat), how: repeat[:how]),
        time_zone: found[:time_zone],
        read: EventRead.new(day: read[:day], time: read[:time], length: read[:length], meal: read[:meal]&.to_sym),
        others: found[:others].map { SayWhen.date(_1) },
        words: found[:words].map { read_word(_1) }
      )
    end
  end
end
