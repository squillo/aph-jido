defmodule JidoAphSmokeTest do
  use ExUnit.Case, async: true

  # Why this test exists: it proves the aph-ex rustler NIF actually compiled
  # and LOADED under this repo's toolchain (a call into APH.Native would raise
  # if it had not), and it pins that APH's strict parse refuses an empty JSON
  # object — "{}" satisfies no required envelope field, and APH parses with
  # unknown/missing fields treated as hard refusals, never silent defaults.
  # Every other build card in PRD-001 depends on this intersection holding.
  test "the NIF loads and strict parse refuses an empty object" do
    assert {:error, _} = APH.parse_envelope_json("{}")
  end
end
