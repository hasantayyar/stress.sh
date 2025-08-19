# stress.sh

Minimal HTTP load testing utility written in Bash with minimal standard system utilities.

## Features

- Concurrency using `xargs -P`
- Duration based or request count based execution
- Global requests per second cap
- Simple concurrency ramp up
- Methods GET POST PUT PATCH DELETE
- Payload from file or inline
- Custom headers
- Keep alive and compression options
- Plain text report including throughput latency percentiles status codes errors
- Exit code based on error rate threshold

## Requirements

- Bash 4 or newer
- curl
- awk
- sort
- xargs
- date
- mktemp
- bc (optional)

## Usage

```bash
./bash-loadtester.sh -u URL -d seconds -c concurrency
./bash-loadtester.sh -u URL -n requests -c concurrency
./bash-loadtester.sh -u URL -d seconds -c concurrency --rps N
./bash-loadtester.sh -u URL -d seconds -c concurrency --ramp start peak steps step_seconds
./bash-loadtester.sh -U urls.txt -d seconds -c concurrency
```

### Parameters

- `-u URL` single target URL
- `-U file` file with one URL per line
- `-d seconds` run for duration
- `-n count` run for fixed number of requests
- `-c concurrency` number of workers
- `--rps N` requests per second cap
- `--ramp start peak steps seconds` ramp concurrency gradually
- `-m METHOD` request method
- `-b file` request body file
- `--data string` inline request body
- `-H "Header: Value"` custom headers
- `--timeout seconds` request timeout
- `--no-keepalive` disable keep alive
- `--no-compress` disable compression
- `--insecure` allow insecure SSL
- `--out dir` output directory for raw results
- `--errbp value` error threshold in basis points
- `--verbose` print per request errors

## Examples

```bash
# Run for 30 seconds with 20 workers
./bash-loadtester.sh -u https://example.com -d 30 -c 20

# Run 1000 requests with 50 workers POST with JSON body
./bash-loadtester.sh -u https://example.com/api -n 1000 -c 50 -m POST -b data.json -H "Content-Type: application/json"

# Run for 60 seconds ramp from 10 to 100 workers over 5 steps with RPS cap 200
./bash-loadtester.sh -u https://example.com -d 60 -c 100 --rps 200 --ramp 10,100,5,5

# Run against multiple targets from file
./bash-loadtester.sh -U urls.txt -d 30 -c 40 --rps 200
```

## Report

Plain text output includes

- Total requests
- Success and failure counts
- Throughput in requests per second
- Latency min avg max p50 p90 p95 p99
- Bytes transferred
- Status code distribution
- Error distribution

## Exit Codes

- Zero if error rate below threshold
- Non zero if error rate exceeds threshold

