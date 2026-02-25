# Spacetimedbex development commands

# Run unit tests (excludes integration)
test:
    mix test

# Run integration tests (requires SpacetimeDB on :3000)
test-integration:
    mix test test/integration_test.exs --include integration

# Run all tests
test-all:
    mix test --include integration

# Lint
credo:
    mix credo

# Compile with strict warnings
compile:
    mix compile --warnings-as-errors

# Full quality check
check: compile test credo

# Build the test WASM module
build-test-module:
    cargo build --manifest-path test_module/Cargo.toml --target wasm32-unknown-unknown --release

# Publish test module to local SpacetimeDB
publish-test-module: build-test-module
    curl -s -X PUT "http://localhost:3000/v1/database/testmodule" \
      -H "Content-Type: application/wasm" \
      --data-binary @test_module/target/wasm32-unknown-unknown/release/test_module.wasm

# Fetch schema from local SpacetimeDB
schema:
    curl -s "http://localhost:3000/v1/database/testmodule/schema?version=9" | python3 -m json.tool

# Interactive Elixir shell with project loaded
shell:
    iex -S mix
