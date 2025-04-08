# fluent-plugin-time-cutoff

[Fluentd](https://fluentd.org/) filter plugin to cut off log records with a timestamp outside of given window.

## Examples

### Example 1: Delete all logs older than 12 hours, pass through records from the future

**Configuration**

``` xml
<filter **>
  @type time_cutoff
  @id time_cutoff
 
  old_cutoff 12h
  old_action drop

  new_action pass
  new_log false
</filter>
```

**Input**

``` bash
# Local time is 2025-04-08T14:43:14+03:00
fluent-cat --event-time '2025-04-08T02:42:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-08T12:42:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-09T14:42:00+03:00' test.cutoff <<< '{"message": "hello"}'
```

**Output**

```
2025-04-08 14:43:24 +0300 [warn]: [time_cutoff] Record caught [old, drop]: "test.cutoff: 2025-04-08T02:42:00+03:00 {"message":"hello"}".
2025-04-08 12:42:00.000000000 +0300 test.cutoff: {"message":"hello"}
2025-04-09 14:42:00.000000000 +0300 test.cutoff: {"message":"hello"}
```

### Example 2: Delete all logs older than 24 hours (omit log), rewrite timestamps for all records newer than 3 hours:

**Configuration**

``` xml
<filter **>
  @type time_cutoff
  @id time_cutoff
 
  old_cutoff 24h
  old_action drop
  old_log false

  new_cutoff 3h
  new_action replace_timestamp
</filter>
```

**Input**

``` bash
# Local time is 2025-04-08T14:48:42+03:00
fluent-cat --event-time '2025-04-07T14:48:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-08T14:48:00+03:00' test.cutoff <<< '{"message": "hello"}'
fluent-cat --event-time '2025-04-08T18:48:00+03:00' test.cutoff <<< '{"message": "hello"}'
```

**Output**

```
2025-04-08 14:48:00.000000000 +0300 test.cutoff: {"message":"hello"}
2025-04-08 14:49:13 +0300 [warn]: [time_cutoff] Record caught [new, replace_timestamp]: "test.cutoff: 2025-04-08T18:48:00+03:00 {"message":"hello"}".
2025-04-08 14:49:13.090783000 +0300 test.cutoff: {"message":"hello","source_time":"2025-04-08T18:48:00+03:00"}
```

## Installation

### RubyGems

```
$ gem install fluent-plugin-time-cutoff
```

### Bundler

Add following line to your Gemfile:

```ruby
gem "fluent-plugin-time-cutoff"
```

And then execute:

```
$ bundle
```

## Configuration

``` xml
<filter **>
  @type time_cutoff
  @id time_cutoff
 
  old_cutoff 24h
  old_action pass
  old_log true

  new_cutoff 24h
  new_action pass
  new_log true

  source_time_key source_time
  source_time_format iso8601
</filter>

```

### old_cutoff (time) (optional)

Records older than this amount of time are deemed "old". Defaults to 24 hours.

Default value: `86400`.

### old_action (enum) (optional)

The action that will be performed to all "old" messages. Defaults to passthrough.

Available values: pass, replace_timestamp, drop

Default value: `pass`.

### old_log (bool) (optional)

Log the "old" messages to Fluentd's own log. Defaults to "true".

Default value: `true`.

### new_cutoff (time) (optional)

Records newer than this amount of time are deemed "new". Defaults to 24 hours.

Default value: `86400`.

### new_action (enum) (optional)

The action that will be performed to all "new" messages. Defaults to passthrough.

Available values: pass, replace_timestamp, drop

Default value: `pass`.

### new_log (bool) (optional)

Log the "new" messages to Fluentd's own log. Defaults to "true".

Default value: `true`.

### source_time_key (string) (optional)

The key that will hold the original time (for :replace_timestamp action). Defaults to "source_time".

Default value: `source_time`.

### source_time_format (enum) (optional)

Time format for the original timestamp field. Defaults to ISO8601-formatted string.

Available values: epoch, epoch_float, iso8601

Default value: `iso8601`.

## Copyright

* Copyright(c) 2025 Qrator Labs and Serge Tkatchouk
* License: MIT
