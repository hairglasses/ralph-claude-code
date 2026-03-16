# Ralph Fix Plan - ralph-claude-code

## High Priority
- [ ] Add a `--max-cost` CLI flag that tracks estimated API spend and halts the loop when the budget is exhausted
- [ ] Add a `--max-hours` CLI flag that gracefully exits after N hours of total runtime
- [ ] Improve stale call counter detection: reset counter if TIMESTAMP_FILE hour is >1 hour old (not just different hour)

## Medium Priority
- [ ] Add retry backoff for transient errors (currently flat 30s sleep on failure)
- [ ] Add a summary report on graceful exit showing total loops, estimated cost, files changed, and duration
- [ ] Improve circuit breaker: track output token trends across loops for cost estimation

## Low Priority
- [ ] Add `--dry-run` flag that validates config and simulates one loop without calling Claude
- [ ] Add log rotation to prevent unbounded log growth during long runs

## Completed
- [x] Project initialization
- [x] Core loop with rate limiting
- [x] Circuit breaker pattern
- [x] Session continuity
- [x] File protection system

## Notes
- Focus on budget safety and long-running stability
- This plan is designed for a 12-hour, $100-budget autonomous run
- Each feature should be properly tested with bats
