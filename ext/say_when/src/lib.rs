//! Native bindings for the `say-when` crate.
//!
//! This layer is deliberately thin: values cross the boundary as plain
//! serde data (days as "YYYY-MM-DD", times as "HH:MM", rules as RRULE
//! strings, offsets as their string form). `lib/say_when.rb` turns those
//! into idiomatic Ruby objects.

use magnus::{function, method, prelude::*, Error, RArray, Ruby, Value};
use say_when_core::{
    Calendar, Day, EventContext, NamedDate, Offset, Options, Reader, Repeat, Time, ZoneNames,
};
use serde::de::DeserializeOwned;

#[magnus::wrap(class = "SayWhen::Native", free_immediately, size)]
struct Native(Reader);

fn arg_error(ruby: &Ruby, message: String) -> Error {
    Error::new(ruby.exception_arg_error(), message)
}

fn from_ruby<T: DeserializeOwned>(ruby: &Ruby, value: Value, what: &str) -> Result<T, Error> {
    serde_magnus::deserialize(ruby, value)
        .map_err(|error| arg_error(ruby, format!("invalid {what}: {error}")))
}

fn to_ruby<T: serde::Serialize>(ruby: &Ruby, value: &T) -> Result<Value, Error> {
    serde_magnus::serialize(ruby, value)
}

fn day(ruby: &Ruby, text: String) -> Result<Day, Error> {
    Day::parse(&text)
        .ok_or_else(|| arg_error(ruby, format!("not a day written YYYY-MM-DD: {text:?}")))
}

fn time(ruby: &Ruby, text: String) -> Result<Time, Error> {
    Time::parse(&text)
        .ok_or_else(|| arg_error(ruby, format!("not a time written HH:MM: {text:?}")))
}

fn opt_time(ruby: &Ruby, text: Option<String>) -> Result<Option<Time>, Error> {
    text.map(|text| time(ruby, text)).transpose()
}

fn offset(ruby: &Ruby, text: String) -> Result<Offset, Error> {
    text.parse::<Offset>()
        .map_err(|error| arg_error(ruby, format!("not an offset: {text:?} ({error})")))
}

/// What a reader is built from, as the Ruby layer sends it: a Hash with
/// string keys, each optional, in the crate's serde shapes.
#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct Config {
    options: Options,
    calendar: Option<Calendar>,
    named_dates: Vec<NamedDate>,
    zones: Option<ZoneNames>,
}

impl Native {
    fn new(ruby: &Ruby, config: Value) -> Result<Native, Error> {
        let config: Config = from_ruby(ruby, config, "reader options")?;
        let mut reader = Reader::new(config.options);
        if let Some(calendar) = config.calendar {
            reader = reader.with_calendar(calendar);
        }
        if !config.named_dates.is_empty() {
            reader = reader.with_named_dates(config.named_dates);
        }
        if let Some(zones) = config.zones {
            reader = reader.with_zones(zones);
        }
        Ok(Native(reader))
    }

    fn about(&self, text: String) -> Native {
        Native(self.0.about(&text))
    }

    fn is_working_day(ruby: &Ruby, rb_self: &Self, on: String) -> Result<bool, Error> {
        Ok(rb_self.0.is_working_day(day(ruby, on)?))
    }

    fn days(ruby: &Ruby, rb_self: &Self, text: String, today: String) -> Result<Value, Error> {
        to_ruby(ruby, &rb_self.0.days(&text, day(ruby, today)?))
    }

    fn span(ruby: &Ruby, rb_self: &Self, text: String, today: String) -> Result<Value, Error> {
        to_ruby(ruby, &rb_self.0.span(&text, day(ruby, today)?))
    }

    fn suggest_days(
        ruby: &Ruby,
        rb_self: &Self,
        typed: String,
        today: String,
    ) -> Result<Value, Error> {
        to_ruby(ruby, &rb_self.0.suggest_days(&typed, day(ruby, today)?))
    }

    fn repeats(
        ruby: &Ruby,
        rb_self: &Self,
        text: String,
        from: String,
        today: String,
    ) -> Result<Value, Error> {
        to_ruby(ruby, &rb_self.0.repeats(&text, day(ruby, from)?, day(ruby, today)?))
    }

    fn suggest_repeats(
        ruby: &Ruby,
        rb_self: &Self,
        from: String,
        today: String,
    ) -> Result<Value, Error> {
        to_ruby(ruby, &rb_self.0.suggest_repeats(day(ruby, from)?, day(ruby, today)?))
    }

    fn describe_repeat(
        ruby: &Ruby,
        rb_self: &Self,
        repeat: Value,
        today: Option<String>,
    ) -> Result<String, Error> {
        let repeat: Repeat = from_ruby(ruby, repeat, "repeat")?;
        let today = today.map(|today| day(ruby, today)).transpose()?;
        Ok(rb_self.0.describe_repeat(&repeat, today))
    }

    fn next_days(
        ruby: &Ruby,
        rb_self: &Self,
        repeat: Value,
        from: String,
        many: usize,
    ) -> Result<Value, Error> {
        let repeat: Repeat = from_ruby(ruby, repeat, "repeat")?;
        to_ruby(ruby, &rb_self.0.next_days(&repeat, day(ruby, from)?, many))
    }

    /// Collected eagerly: the crate's iterator borrows the reader, which
    /// can't be handed to Ruby.
    fn repeat_days(
        ruby: &Ruby,
        rb_self: &Self,
        repeat: Value,
        from: String,
        to: String,
    ) -> Result<RArray, Error> {
        let repeat: Repeat = from_ruby(ruby, repeat, "repeat")?;
        let days = rb_self.0.repeat_days(&repeat, day(ruby, from)?, day(ruby, to)?);
        Ok(ruby.ary_from_iter(days.map(|day| day.to_string())))
    }

    fn repeats_on(ruby: &Ruby, rb_self: &Self, repeat: Value, on: String) -> Result<bool, Error> {
        let repeat: Repeat = from_ruby(ruby, repeat, "repeat")?;
        Ok(rb_self.0.repeats_on(&repeat, day(ruby, on)?))
    }

    fn last_repeat_day(
        ruby: &Ruby,
        rb_self: &Self,
        repeat: Value,
    ) -> Result<Option<String>, Error> {
        let repeat: Repeat = from_ruby(ruby, repeat, "repeat")?;
        Ok(rb_self.0.last_repeat_day(&repeat).map(|day| day.to_string()))
    }

    fn time(
        ruby: &Ruby,
        rb_self: &Self,
        text: String,
        after: Option<String>,
    ) -> Result<Option<String>, Error> {
        Ok(rb_self.0.time(&text, opt_time(ruby, after)?).map(|time| time.to_string()))
    }

    fn offset(&self, text: String) -> Option<String> {
        self.0.offset(&text).map(|offset| offset.to_string())
    }

    /// `[day, time_or_nil]`, or nil when it lands nowhere.
    fn offset_from(
        ruby: &Ruby,
        rb_self: &Self,
        text: String,
        on: String,
        at: Option<String>,
    ) -> Result<Option<(String, Option<String>)>, Error> {
        let offset = offset(ruby, text)?;
        let landed = rb_self.0.offset_from(&offset, day(ruby, on)?, opt_time(ruby, at)?);
        Ok(landed.map(|(day, time)| (day.to_string(), time.map(|time| time.to_string()))))
    }

    fn event(ruby: &Ruby, rb_self: &Self, text: String, context: Value) -> Result<Value, Error> {
        let context: EventContext = from_ruby(ruby, context, "event context")?;
        to_ruby(ruby, &rb_self.0.event(&text, &context))
    }

    fn when(ruby: &Ruby, rb_self: &Self, text: String, today: String) -> Result<Value, Error> {
        to_ruby(ruby, &rb_self.0.when(&text, day(ruby, today)?))
    }

    fn corrected(&self, typed: String, more: Vec<String>) -> Option<String> {
        let more: Vec<&str> = more.iter().map(String::as_str).collect();
        self.0.corrected(&typed, &more)
    }
}

fn easter(year: i32) -> Option<String> {
    say_when_core::easter(year).map(|day| day.to_string())
}

fn read_clock(ruby: &Ruby, text: String, after: Option<String>) -> Result<Option<String>, Error> {
    Ok(say_when_core::read_clock(&text, opt_time(ruby, after)?).map(|time| time.to_string()))
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("SayWhen")?;
    module.define_singleton_method("_easter", function!(easter, 1))?;
    module.define_singleton_method("_read_clock", function!(read_clock, 2))?;

    let class = module.define_class("Native", ruby.class_object())?;
    class.define_singleton_method("new", function!(Native::new, 1))?;
    class.define_method("about", method!(Native::about, 1))?;
    class.define_method("working_day?", method!(Native::is_working_day, 1))?;
    class.define_method("days", method!(Native::days, 2))?;
    class.define_method("span", method!(Native::span, 2))?;
    class.define_method("suggest_days", method!(Native::suggest_days, 2))?;
    class.define_method("repeats", method!(Native::repeats, 3))?;
    class.define_method("suggest_repeats", method!(Native::suggest_repeats, 2))?;
    class.define_method("describe_repeat", method!(Native::describe_repeat, 2))?;
    class.define_method("next_days", method!(Native::next_days, 3))?;
    class.define_method("repeat_days", method!(Native::repeat_days, 3))?;
    class.define_method("repeats_on?", method!(Native::repeats_on, 2))?;
    class.define_method("last_repeat_day", method!(Native::last_repeat_day, 1))?;
    class.define_method("time", method!(Native::time, 2))?;
    class.define_method("offset", method!(Native::offset, 1))?;
    class.define_method("offset_from", method!(Native::offset_from, 3))?;
    class.define_method("event", method!(Native::event, 2))?;
    class.define_method("when", method!(Native::when, 2))?;
    class.define_method("corrected", method!(Native::corrected, 2))?;
    Ok(())
}
