# SayWhen

Ruby bindings for the [say-when](https://crates.io/crates/say-when) Rust crate (pinned to `=0.1.3`). It reads days, spans of days, times and how things repeat, written in plain English, the way people type them into a date picker or calendar.

## Installation

```ruby
gem "say_when_rb"
```

The gem is published as `say_when_rb` because the `say_when` name is taken, but you still `require "say_when"` and use the `SayWhen` module.

Precompiled gems are published for Linux, macOS and Windows. On other platforms, or Rubies without a precompiled build, the gem compiles from source, which needs Rust ≥ 1.90 (the crate uses edition 2024).

## Usage

```ruby
require "say_when"

reader = SayWhen::Reader.new(locale: :uk) # :uk, :us, :ireland, :australia, :new_zealand, :canada
today  = Date.new(2026, 10, 20)           # date-reading methods take `today:` (defaults to the system-local Date.today)

# Days
read = reader.days("the day before the last working day of november", today:)
read.first.day # => #<Date: 2026-11-29>
read.first.how # => "the day before Mon 30 Nov, the last working day of November 2026"
reader.day("next fri", today:) # => likeliest Date, or nil

# Spans
reader.span("q3 2027", today:) # => #<data SayWhen::SpanReading first=2027-07-01, last=2027-09-30, kind=:quarter>

# Date-picker search, as it's typed
reader.suggest_days("t", today:).map(&:name) # => ["Today", "Tomorrow", "Tuesday", "Thursday"]

# Repeats, as iCalendar RRULEs
reading = reader.repeats("every other thursday until christmas", from: today, today:).first
reading.repeat.rule # => "FREQ=WEEKLY;INTERVAL=2;BYDAY=TH;UNTIL=20261225"
reading.how         # => "Every 2 weeks on Thursday, until 25 December"
reader.next_days(reading.repeat, limit: 10)
reader.repeat_days(reading.repeat, from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30))
reader.repeats_on?(reading.repeat, Date.new(2026, 11, 5))
reader.last_repeat_day(reading.repeat)

# Times of day (SayWhen::ClockTime, since Ruby has no time-of-day type)
reader.time("half three") # => #<SayWhen::ClockTime 15:30>

# Offsets, e.g. reminders relative to an event
offset = reader.offset("the day before at 9am") # => "-P1D@09:00" (store this string)
reader.offset_from(offset, Date.new(2026, 12, 3), "14:00") # => [#<Date: 2026-12-02>, #<SayWhen::ClockTime 09:00>]

# Events typed as a sentence
text  = "Lunch with #Priya tomorrow 1-2pm at Dishoom"
event = reader.event(text, today:, mentions: { "#Priya" => "Priya" })
event.title      # => "Lunch with Priya"
event.start_time # => #<SayWhen::ClockTime 13:00>
event.location   # => "Dishoom"
event.words.map { [_1.text(text), _1.role] } # word offsets are bytes; ReadWord#text slices correctly

# Just "when", for search or free-slot finding
reader.when("fri 6pm to sun 5pm", today:) # => SayWhen::WhenReading, or nil if anything else was typed
```

### What the reader is told

The crate has no clock, time zones or holiday data of its own. You provide them:

```ruby
reader = SayWhen::Reader.new(
  locale: :us,
  calendar: {
    days_off: [{ day: Date.new(2026, 11, 26), name: "Thanksgiving" }], # or bare Dates
    named_days: [{ day: SayWhen.easter(2027), names: ["Easter Sunday", "Easter"] },
                 { day: Date.new(2027, 2, 8), last: Date.new(2027, 3, 9), names: ["Ramadan"] }],
    working_week: %i[monday tuesday wednesday thursday friday]
  },
  named_dates: [{ names: ["eli", "eli jones"], what: ["birthday"], month: 3, day: 14, label: "Eli Jones’s birthday" }],
  zones: { before_word_time: { "new york" => "America/New_York" }, after_a_time: { "pt" => "America/Los_Angeles" } }
)

reader.about("Plan Eli's party").day("his birthday") # "his" now means Eli
```

Readers are immutable. Build one and reuse it, because construction does the setup work. Bad input such as unknown locales, malformed dates or invalid rules raises `ArgumentError`.

## Design

- `ext/say_when/src/lib.rs` is a thin [magnus](https://github.com/matsadler/magnus) layer. Values cross the boundary as the crate's own serde shapes via [serde_magnus](https://github.com/OneSignal/serde-magnus): days are `"YYYY-MM-DD"` strings, times are `"HH:MM"` strings, rules are RRULE strings and offsets use their string form.
- `lib/say_when.rb` converts those to and from `Date`, `SayWhen::ClockTime` and `Data` value objects.

## Development

```bash
bin/setup
bundle exec rake compile spec
bundle exec rake build   # source gem; stage new files in git first, since spec.files uses `git ls-files`
```

## Releasing

Each version is published as several `.gem` files: a **source gem**, which compiles the Rust extension on install and needs a Rust toolchain, and one **precompiled native gem per platform**, which installs without one. RubyGems picks the most specific match for each machine and falls back to the source gem.

### Target platforms

| Platform | OS |
|---|---|
| `x86_64-linux`, `aarch64-linux` | Linux (glibc) |
| `x86_64-linux-musl`, `aarch64-linux-musl` | Alpine and other musl Linux |
| `x86_64-darwin`, `arm64-darwin` | macOS (Intel, Apple Silicon) |
| `x64-mingw-ucrt` | Windows |

Each native gem bundles one compiled library per supported Ruby minor version, at `lib/say_when/<ruby-minor>/say_when.{so,bundle}`. `lib/say_when.rb` must load the versioned library first and fall back to `say_when/say_when` for source installs.

### Building native gems

Native gems are cross-compiled from Linux using the [rb-sys-dock](https://github.com/oxidize-rb/rb-sys) Docker images. In CI, use the [`oxidize-rb/actions/cross-gem`](https://github.com/oxidize-rb/actions) GitHub Action, with a build matrix over the platforms above:

```yaml
- uses: oxidize-rb/actions/setup-ruby-and-rust@v1
  with: { ruby-version: "3.4", bundler-cache: true, cargo-cache: true }
- uses: oxidize-rb/actions/cross-gem@v1
  id: cross-gem
  with:
    platform: ${{ matrix.platform }}
    ruby-versions: "3.2,3.3,3.4" # keep in line with required_ruby_version
- uses: actions/upload-artifact@v4
  with:
    name: gem-${{ matrix.platform }}
    path: ${{ steps.cross-gem.outputs.gem-path }}
```

To build one platform locally (needs Docker):

```bash
bundle exec rb-sys-dock --platform x86_64-linux --build
```

The source gem is built with `bundle exec rake build`, which writes `pkg/say_when_rb-<version>.gem`.

### Release steps

1. Bump `SayWhen::VERSION` in `lib/say_when/version.rb`, update the changelog if there is one, and commit. `spec.files` uses `git ls-files`, so anything uncommitted is left out of the gem.
2. Tag and push: `git tag vX.Y.Z && git push origin main vX.Y.Z`.
3. The tag runs `.github/workflows/release.yml`, which:
   - builds the source gem and every native gem;
   - installs each native gem on its OS (Linux x86_64 and ARM, macOS Intel and Apple Silicon, Windows) under every supported Ruby, and checks that it loads and reads a date;
   - if all of that passes, pushes every gem to RubyGems with `gem push`.

   To build and test without publishing, run the workflow by hand from the Actions tab (`workflow_dispatch`).

Publishing uses [RubyGems trusted publishing](https://guides.rubygems.org/trusted-publishing/), so no API key is stored. On rubygems.org, add a trusted publisher for this repository with workflow `release.yml` and environment `release`. Before the gem's first release, add it as a pending trusted publisher. Then create a `release` environment in the GitHub repository settings, and optionally require approval there to gate each publish.

Release builds keep debug symbols (`debug = true` in the root `Cargo.toml`), which makes native gems much larger. Set `strip = true` there if size matters more than debuggability.

## License

MIT. The wrapped crate is MIT-licensed, © Joel Drapper.
