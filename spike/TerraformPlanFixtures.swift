// Real `terraform` output, captured by running Terraform 1.17.1 (linux_amd64)
// against the built-in `terraform_data` resource, so nothing here is invented
// and nothing needed a cloud account:
//
//   create            three new resources, one holding a sensitive value
//   noop              nothing to do
//   outputsOnly       only an output changes
//   mixed             create + replace + destroy + update in one plan
//   tainted           `terraform taint`, so "is tainted, so must be replaced"
//   replaceRequested  `-replace=ADDRESS`
//   moved             a `moved` block
//   movedAndUpdated   a `moved` block and an in-place update together
//   forget            a `removed` block with `destroy = false`
//   imported          an `import` block (plus a forget)
//   errored           a resource precondition fails while planning
//
// OpenTofu 1.13.2 is covered too (the `tofu...` names, same scenarios). Its
// wording differs from Terraform's where it matters: a forget is "will be
// removed from the OpenTofu state", the failure sentences open with
// "OpenTofu", and its change_summary has a `forget` count of its own.
//
// Each one is kept in the three shapes a workflow can print: `...Text` (the
// human `plan`, no colour unless the name says so), `...JSON`
// (`show -json` of the saved plan) and `...Stream` (`plan -json`).
//
// Text is verbatim, with the ESC byte written as an escape. The JSON keeps the
// fields the parser reads and drops `configuration`, `prior_state` and the
// like. The streams drop the refresh and progress chatter. Used by
// `TerraformPlanVerify`; the source is `terraform_data` resources only, e.g.
//
//   resource "terraform_data" "pw" {
//     input = { user = "admin", password = sensitive("hunter2") }
//   }
enum TerraformFixtures {
    static let createText = #"""

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # terraform_data.db will be created
  + resource "terraform_data" "db" {
      + id               = (known after apply)
      + triggers_replace = [
          + "v1",
        ]
    }

  # terraform_data.pw will be created
  + resource "terraform_data" "pw" {
      + id     = (known after apply)
      + input  = {
          + password = (sensitive value)
          + user     = "admin"
        }
      + output = (known after apply)
    }

  # terraform_data.web will be created
  + resource "terraform_data" "web" {
      + id     = (known after apply)
      + input  = "hello"
      + output = (known after apply)
    }

Plan: 3 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + greeting = (known after apply)
  + x        = "one"

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let createJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":null,"output":null,"store":null,"triggers_replace":["v1"]},"after_unknown":{"id":true,"triggers_replace":[false]},"before_sensitive":false,"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":{"password":"hunter2","user":"admin"},"store":null,"triggers_replace":null},"after_unknown":{"id":true,"input":{},"output":true},"before_sensitive":false,"after_sensitive":{"input":{"password":true},"output":{}}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":"hello","store":null,"triggers_replace":null},"after_unknown":{"id":true,"output":true},"before_sensitive":false,"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["create"],"before":null,"after_unknown":true,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["create"],"before":null,"after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let createStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:42.885125+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.pw: Plan to create","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:42.891269+01:00","change":{"resource":{"addr":"terraform_data.pw","module":"","resource":"terraform_data.pw","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"pw","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.web: Plan to create","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:42.891343+01:00","change":{"resource":{"addr":"terraform_data.web","module":"","resource":"terraform_data.web","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"web","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.db: Plan to create","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:42.891352+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 3 to add, 0 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:42.891359+01:00","changes":{"add":3,"change":0,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:42.891396+01:00","outputs":{"greeting":{"sensitive":false,"action":"create"},"x":{"sensitive":false,"action":"create"}},"type":"outputs"}
"""#

    static let noopText = #"""
terraform_data.db: Refreshing state... [id=c6ee93b5-34d4-847e-da94-01266b7c9592]
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.pw: Refreshing state... [id=9ac8eed3-a35f-7e2c-80da-0035ff2575aa]

No changes. Your infrastructure matches the configuration.

Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
"""#

    static let noopJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":false,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c6ee93b5-34d4-847e-da94-01266b7c9592","input":null,"output":null,"store":null,"triggers_replace":["v1"]},"after":{"id":"c6ee93b5-34d4-847e-da94-01266b7c9592","input":null,"output":null,"store":null,"triggers_replace":["v1"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"9ac8eed3-a35f-7e2c-80da-0035ff2575aa","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"store":null,"triggers_replace":null},"after":{"id":"9ac8eed3-a35f-7e2c-80da-0035ff2575aa","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{"input":{"password":true},"output":{}},"after_sensitive":{"input":{"password":true},"output":{}}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello","output":"hello","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello","output":"hello","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello","after":"hello","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let noopStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.137105+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.145588+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.145638+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let outputsOnlyText = #"""
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.db: Refreshing state... [id=c6ee93b5-34d4-847e-da94-01266b7c9592]
terraform_data.pw: Refreshing state... [id=9ac8eed3-a35f-7e2c-80da-0035ff2575aa]

Changes to Outputs:
  ~ x        = "one" -> "two"

You can apply this plan to save these new output values to the Terraform
state, without changing any real infrastructure.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let outputsOnlyJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c6ee93b5-34d4-847e-da94-01266b7c9592","input":null,"output":null,"store":null,"triggers_replace":["v1"]},"after":{"id":"c6ee93b5-34d4-847e-da94-01266b7c9592","input":null,"output":null,"store":null,"triggers_replace":["v1"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"9ac8eed3-a35f-7e2c-80da-0035ff2575aa","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"store":null,"triggers_replace":null},"after":{"id":"9ac8eed3-a35f-7e2c-80da-0035ff2575aa","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{"input":{"password":true},"output":{}},"after_sensitive":{"input":{"password":true},"output":{}}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello","output":"hello","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello","output":"hello","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello","after":"hello","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["update"],"before":"one","after":"two","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let outputsOnlyStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.340595+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.350752+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.350804+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"update"}},"type":"outputs"}
"""#

    static let mixedText = #"""
terraform_data.pw: Refreshing state... [id=9ac8eed3-a35f-7e2c-80da-0035ff2575aa]
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.db: Refreshing state... [id=c6ee93b5-34d4-847e-da94-01266b7c9592]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create
  ~ update in-place
  - destroy
-/+ destroy and then create replacement

Terraform will perform the following actions:

  # terraform_data.cache will be created
  + resource "terraform_data" "cache" {
      + id     = (known after apply)
      + input  = "fresh"
      + output = (known after apply)
    }

  # terraform_data.db must be replaced
-/+ resource "terraform_data" "db" {
      ~ id               = "c6ee93b5-34d4-847e-da94-01266b7c9592" -> (known after apply)
      ~ triggers_replace = [
          ~ "v1" -> "v2",
        ]
    }

  # terraform_data.pw will be destroyed
  # (because terraform_data.pw is not in configuration)
  - resource "terraform_data" "pw" {
      - id     = "9ac8eed3-a35f-7e2c-80da-0035ff2575aa" -> null
      - input  = {
          - password = (sensitive value)
          - user     = "admin"
        } -> null
      - output = {
          - password = "hunter2"
          - user     = "admin"
        } -> null
    }

  # terraform_data.web will be updated in-place
  ~ resource "terraform_data" "web" {
        id     = "8a5ff74d-f0ec-eaae-9d86-21c3e29de92e"
      ~ input  = "hello" -> "hello again"
      ~ output = "hello" -> (known after apply)
    }

Plan: 2 to add, 1 to change, 2 to destroy.

Changes to Outputs:
  ~ greeting = "hello" -> (known after apply)

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let mixedColourText = #"""
\#u{1B}[0m\#u{1B}[1mterraform_data.pw: Refreshing state... [id=9ac8eed3-a35f-7e2c-80da-0035ff2575aa]\#u{1B}[0m
\#u{1B}[0m\#u{1B}[1mterraform_data.db: Refreshing state... [id=c6ee93b5-34d4-847e-da94-01266b7c9592]\#u{1B}[0m
\#u{1B}[0m\#u{1B}[1mterraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]\#u{1B}[0m

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  \#u{1B}[32m+\#u{1B}[0m create\#u{1B}[0m
  \#u{1B}[33m~\#u{1B}[0m update in-place\#u{1B}[0m
  \#u{1B}[31m-\#u{1B}[0m destroy\#u{1B}[0m
\#u{1B}[31m-\#u{1B}[0m/\#u{1B}[32m+\#u{1B}[0m destroy and then create replacement\#u{1B}[0m

Terraform will perform the following actions:

\#u{1B}[1m  # terraform_data.cache\#u{1B}[0m will be created
\#u{1B}[0m  \#u{1B}[32m+\#u{1B}[0m\#u{1B}[0m resource "terraform_data" "cache" {
      \#u{1B}[32m+\#u{1B}[0m\#u{1B}[0m id     = (known after apply)
      \#u{1B}[32m+\#u{1B}[0m\#u{1B}[0m input  = "fresh"
      \#u{1B}[32m+\#u{1B}[0m\#u{1B}[0m output = (known after apply)
    }

\#u{1B}[1m  # terraform_data.db\#u{1B}[0m must be \#u{1B}[1m\#u{1B}[31mreplaced\#u{1B}[0m
\#u{1B}[0m\#u{1B}[31m-\#u{1B}[0m/\#u{1B}[32m+\#u{1B}[0m\#u{1B}[0m resource "terraform_data" "db" {
      \#u{1B}[33m~\#u{1B}[0m\#u{1B}[0m id               = "c6ee93b5-34d4-847e-da94-01266b7c9592" -> (known after apply)
      \#u{1B}[33m~\#u{1B}[0m\#u{1B}[0m triggers_replace = [
          \#u{1B}[33m~\#u{1B}[0m\#u{1B}[0m "v1" \#u{1B}[33m->\#u{1B}[0m\#u{1B}[0m "v2",
        ]
    }

\#u{1B}[1m  # terraform_data.pw\#u{1B}[0m will be \#u{1B}[1m\#u{1B}[31mdestroyed\#u{1B}[0m
  # (because terraform_data.pw is not in configuration)
\#u{1B}[0m  \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m resource "terraform_data" "pw" {
      \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m id     = "9ac8eed3-a35f-7e2c-80da-0035ff2575aa" \#u{1B}[90m-> null\#u{1B}[0m\#u{1B}[0m
      \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m input  = {
          \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m password = (sensitive value)
          \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m user     = "admin"
        } \#u{1B}[90m-> null\#u{1B}[0m\#u{1B}[0m
      \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m output = {
          \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m password = "hunter2"
          \#u{1B}[31m-\#u{1B}[0m\#u{1B}[0m user     = "admin"
        } \#u{1B}[90m-> null\#u{1B}[0m\#u{1B}[0m
    }

\#u{1B}[1m  # terraform_data.web\#u{1B}[0m will be updated in-place
\#u{1B}[0m  \#u{1B}[33m~\#u{1B}[0m\#u{1B}[0m resource "terraform_data" "web" {
        id     = "8a5ff74d-f0ec-eaae-9d86-21c3e29de92e"
      \#u{1B}[33m~\#u{1B}[0m\#u{1B}[0m input  = "hello" \#u{1B}[33m->\#u{1B}[0m\#u{1B}[0m "hello again"
      \#u{1B}[33m~\#u{1B}[0m\#u{1B}[0m output = "hello" -> (known after apply)
    }

\#u{1B}[1mPlan:\#u{1B}[0m \#u{1B}[0m2 to add, 1 to change, 2 to destroy.

Changes to Outputs:
  \#u{1B}[33m~\#u{1B}[0m\#u{1B}[0m greeting = "hello" -> (known after apply)
\#u{1B}[90m
─────────────────────────────────────────────────────────────────────────────\#u{1B}[0m

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let mixedJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"cache","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":"fresh","store":null,"triggers_replace":null},"after_unknown":{"id":true,"output":true},"before_sensitive":false,"after_sensitive":{}}},{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete","create"],"before":{"id":"c6ee93b5-34d4-847e-da94-01266b7c9592","input":null,"output":null,"store":null,"triggers_replace":["v1"]},"after":{"input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after_unknown":{"id":true,"triggers_replace":[false]},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]},"replace_paths":[["triggers_replace"]]},"action_reason":"replace_because_cannot_update"},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete"],"before":{"id":"9ac8eed3-a35f-7e2c-80da-0035ff2575aa","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"store":null,"triggers_replace":null},"after":null,"after_unknown":{},"before_sensitive":{"input":{"password":true},"output":{}},"after_sensitive":false},"action_reason":"delete_because_no_resource_config"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["update"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello","output":"hello","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","store":null,"triggers_replace":null},"after_unknown":{"output":true},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["update"],"before":"hello","after_unknown":true,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let mixedStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.545784+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.web: Plan to update","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.552631+01:00","change":{"resource":{"addr":"terraform_data.web","module":"","resource":"terraform_data.web","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"web","resource_key":null},"action":"update"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.cache: Plan to create","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.552674+01:00","change":{"resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.db: Plan to replace","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.552682+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"replace","reason":"cannot_update"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.pw: Plan to delete","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.552693+01:00","change":{"resource":{"addr":"terraform_data.pw","module":"","resource":"terraform_data.pw","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"pw","resource_key":null},"action":"delete","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 2 to add, 1 to change, 2 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.552700+01:00","changes":{"add":2,"change":1,"import":0,"remove":2,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.552725+01:00","outputs":{"greeting":{"sensitive":false,"action":"update"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let taintedText = #"""
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.db: Refreshing state... [id=33e03ad0-acd7-9304-325a-61e5eef62e04]
terraform_data.cache: Refreshing state... [id=26936e61-de4f-1c34-b77b-bda526b2c7a2]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
-/+ destroy and then create replacement

Terraform will perform the following actions:

  # terraform_data.db is tainted, so must be replaced
-/+ resource "terraform_data" "db" {
      ~ id               = "33e03ad0-acd7-9304-325a-61e5eef62e04" -> (known after apply)
        # (1 unchanged attribute hidden)
    }

Plan: 1 to add, 0 to change, 1 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let taintedJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"cache","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}},{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete","create"],"before":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after":{"input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after_unknown":{"id":true,"triggers_replace":[false]},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}},"action_reason":"replace_because_tainted"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let taintedStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.836143+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.db: Plan to replace","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.844907+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"replace","reason":"tainted"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to add, 0 to change, 1 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.844974+01:00","changes":{"add":1,"change":0,"import":0,"remove":1,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:43.845010+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let replaceRequestedText = #"""
terraform_data.db: Refreshing state... [id=33e03ad0-acd7-9304-325a-61e5eef62e04]
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.cache: Refreshing state... [id=26936e61-de4f-1c34-b77b-bda526b2c7a2]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
-/+ destroy and then create replacement

Terraform will perform the following actions:

  # terraform_data.cache will be replaced, as requested
-/+ resource "terraform_data" "cache" {
      ~ id     = "26936e61-de4f-1c34-b77b-bda526b2c7a2" -> (known after apply)
      ~ output = "fresh" -> (known after apply)
        # (1 unchanged attribute hidden)
    }

Plan: 1 to add, 0 to change, 1 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let replaceRequestedJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"cache","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete","create"],"before":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after":{"input":"fresh","store":null,"triggers_replace":null},"after_unknown":{"id":true,"output":true},"before_sensitive":{},"after_sensitive":{}},"action_reason":"replace_by_request"},{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let replaceRequestedStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.068712+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.cache: Plan to replace","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.077297+01:00","change":{"resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"replace","reason":"requested"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to add, 0 to change, 1 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.077393+01:00","changes":{"add":1,"change":0,"import":0,"remove":1,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.077420+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let movedText = #"""
terraform_data.store: Refreshing state... [id=26936e61-de4f-1c34-b77b-bda526b2c7a2]
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.db: Refreshing state... [id=33e03ad0-acd7-9304-325a-61e5eef62e04]

Terraform will perform the following actions:

  # terraform_data.cache has moved to terraform_data.store
    resource "terraform_data" "store" {
        id     = "26936e61-de4f-1c34-b77b-bda526b2c7a2"
        # (2 unchanged attributes hidden)
    }

Plan: 0 to add, 0 to change, 0 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let movedJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.store","previous_address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let movedStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.272746+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.store: Plan to move","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.282670+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"previous_resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"move"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.282760+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.282784+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let movedAndUpdatedText = #"""
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.store: Refreshing state... [id=26936e61-de4f-1c34-b77b-bda526b2c7a2]
terraform_data.db: Refreshing state... [id=33e03ad0-acd7-9304-325a-61e5eef62e04]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  ~ update in-place

Terraform will perform the following actions:

  # terraform_data.store will be updated in-place
  # (moved from terraform_data.cache)
  ~ resource "terraform_data" "store" {
        id     = "26936e61-de4f-1c34-b77b-bda526b2c7a2"
      ~ input  = "fresh" -> "fresher"
      ~ output = "fresh" -> (known after apply)
    }

Plan: 0 to add, 1 to change, 0 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let movedAndUpdatedJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.store","previous_address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["update"],"before":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresher","store":null,"triggers_replace":null},"after_unknown":{"output":true},"before_sensitive":{},"after_sensitive":{}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let movedAndUpdatedStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.481067+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.store: Plan to update","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.490157+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"previous_resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"update"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 1 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.490211+01:00","changes":{"add":0,"change":1,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.490231+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let forgetText = #"""
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.db: Refreshing state... [id=33e03ad0-acd7-9304-325a-61e5eef62e04]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:

Terraform will perform the following actions:

 # terraform_data.store will no longer be managed by Terraform, but will not be destroyed
 # (destroy = false is set in the configuration)
 . resource "terraform_data" "store" {
        id     = "26936e61-de4f-1c34-b77b-bda526b2c7a2"
        # (2 unchanged attributes hidden)
    }

Plan: 0 to add, 0 to change, 0 to destroy.

Warning: Some objects will no longer be managed by Terraform

If you apply this plan, Terraform will discard its tracking information for
the following objects, but it will not delete them:
 - terraform_data.store

After applying this plan, Terraform will no longer manage these objects. You
will need to import them into Terraform to manage them again.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let forgetJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.store","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["forget"],"before":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after":null,"after_unknown":{},"before_sensitive":{},"after_sensitive":false},"action_reason":"delete_because_no_resource_config"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let forgetStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.724434+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.store: Plan to remove","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.733553+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"action":"remove","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.733644+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.733671+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
{"@level":"warn","@message":"Warning: Some objects will no longer be managed by Terraform","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.733692+01:00","diagnostic":{"severity":"warning","summary":"Some objects will no longer be managed by Terraform","detail":"If you apply this plan, Terraform will discard its tracking information for the following objects, but it will not delete them:\n - terraform_data.store\n\nAfter applying this plan, Terraform will no longer manage these objects. You will need to import them into Terraform to manage them again."},"type":"diagnostic"}
"""#

    static let importedText = #"""
terraform_data.imp: Preparing import... [id=imported-1]
terraform_data.imp: Refreshing state... [id=imported-1]
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]
terraform_data.db: Refreshing state... [id=33e03ad0-acd7-9304-325a-61e5eef62e04]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  ~ update in-place

Terraform will perform the following actions:

  # terraform_data.imp will be updated in-place
  # (imported from "imported-1")
  ~ resource "terraform_data" "imp" {
        id     = "imported-1"
      + input  = "imported-1"
      + output = (known after apply)
    }

 # terraform_data.store will no longer be managed by Terraform, but will not be destroyed
 # (destroy = false is set in the configuration)
 . resource "terraform_data" "store" {
        id     = "26936e61-de4f-1c34-b77b-bda526b2c7a2"
        # (2 unchanged attributes hidden)
    }

Plan: 1 to import, 0 to add, 1 to change, 0 to destroy.

Warning: Some objects will no longer be managed by Terraform

If you apply this plan, Terraform will discard its tracking information for
the following objects, but it will not delete them:
 - terraform_data.store

After applying this plan, Terraform will no longer manage these objects. You
will need to import them into Terraform to manage them again.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.
"""#

    static let importedJSON = #"""
{"format_version":"1.2","terraform_version":"1.17.1","applyable":true,"complete":true,"errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after":{"id":"33e03ad0-acd7-9304-325a-61e5eef62e04","input":null,"output":null,"store":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.imp","mode":"managed","type":"terraform_data","name":"imp","provider_name":"terraform.io/builtin/terraform","change":{"actions":["update"],"before":{"id":"imported-1","input":null,"output":null,"store":null,"triggers_replace":null},"after":{"id":"imported-1","input":"imported-1","store":null,"triggers_replace":null},"after_unknown":{"output":true},"before_sensitive":{},"after_sensitive":{},"importing":{"id":"imported-1"}}},{"address":"terraform_data.store","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["forget"],"before":{"id":"26936e61-de4f-1c34-b77b-bda526b2c7a2","input":"fresh","output":"fresh","store":null,"triggers_replace":null},"after":null,"after_unknown":{},"before_sensitive":{},"after_sensitive":false},"action_reason":"delete_because_no_resource_config"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after":{"id":"8a5ff74d-f0ec-eaae-9d86-21c3e29de92e","input":"hello again","output":"hello again","store":null,"triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let importedStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.938083+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.store: Plan to remove","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.947767+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"action":"remove","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.imp: Plan to update","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.947825+01:00","change":{"resource":{"addr":"terraform_data.imp","module":"","resource":"terraform_data.imp","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"imp","resource_key":null},"action":"update","importing":{"id":"imported-1"}},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to import, 0 to add, 1 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.947835+01:00","changes":{"add":0,"change":1,"import":1,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.947854+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
{"@level":"warn","@message":"Warning: Some objects will no longer be managed by Terraform","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:44.947876+01:00","diagnostic":{"severity":"warning","summary":"Some objects will no longer be managed by Terraform","detail":"If you apply this plan, Terraform will discard its tracking information for the following objects, but it will not delete them:\n - terraform_data.store\n\nAfter applying this plan, Terraform will no longer manage these objects. You will need to import them into Terraform to manage them again."},"type":"diagnostic"}
"""#

    static let erroredText = #"""
terraform_data.db: Refreshing state... [id=33e03ad0-acd7-9304-325a-61e5eef62e04]
terraform_data.store: Refreshing state... [id=26936e61-de4f-1c34-b77b-bda526b2c7a2]
terraform_data.web: Refreshing state... [id=8a5ff74d-f0ec-eaae-9d86-21c3e29de92e]

Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  - destroy

Terraform planned the following actions, but then encountered a problem:

  # terraform_data.db will be destroyed
  # (because terraform_data.db is not in configuration)
  - resource "terraform_data" "db" {
      - id               = "33e03ad0-acd7-9304-325a-61e5eef62e04" -> null
      - triggers_replace = [
          - "v2",
        ] -> null
    }

  # terraform_data.store will be destroyed
  # (because terraform_data.store is not in configuration)
  - resource "terraform_data" "store" {
      - id     = "26936e61-de4f-1c34-b77b-bda526b2c7a2" -> null
      - input  = "fresh" -> null
      - output = "fresh" -> null
    }

Plan: 0 to add, 0 to change, 2 to destroy.

Changes to Outputs:
  - greeting = "hello again" -> null
  - x        = "one" -> null

Error: Resource precondition failed

  on main.tf line 11, in resource "terraform_data" "late":
  11:       condition     = var.x == "never"
    ├────────────────
    │ var.x is "one"

x must be never
"""#

    static let erroredStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:45.099412+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.db: Plan to delete","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:45.107116+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"delete","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.store: Plan to delete","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:45.107159+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"action":"delete","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 2 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:45.107170+01:00","changes":{"add":0,"change":0,"import":0,"remove":2,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:45.107202+01:00","outputs":{"greeting":{"sensitive":false,"action":"delete"},"x":{"sensitive":false,"action":"delete"}},"type":"outputs"}
{"@level":"error","@message":"Error: Resource precondition failed","@module":"terraform.ui","@timestamp":"2026-11-02T09:10:45.107529+01:00","diagnostic":{"severity":"error","summary":"Resource precondition failed","detail":"x must be never","range":{"filename":"main.tf","start":{"line":11,"column":23,"byte":202},"end":{"line":11,"column":39,"byte":218}},"snippet":{"context":"resource \"terraform_data\" \"late\"","code":"      condition     = var.x == \"never\"","start_line":11,"highlight_start_offset":22,"highlight_end_offset":38,"values":[{"traversal":"var.x","statement":"is \"one\""}]}},"type":"diagnostic"}
"""#

    static let applySuccessStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.275482+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.a: Plan to create","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.279820+01:00","change":{"resource":{"addr":"terraform_data.a","module":"","resource":"terraform_data.a","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"a","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to add, 0 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.280028+01:00","changes":{"add":1,"change":0,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"terraform_data.a: Creating...","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.281606+01:00","hook":{"resource":{"addr":"terraform_data.a","module":"","resource":"terraform_data.a","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"a","resource_key":null},"action":"create"},"type":"apply_start"}
{"@level":"info","@message":"terraform_data.a: Creation complete after 0s [id=b3b64609-1f34-11e9-afe0-fcee7aa7b21d]","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.281879+01:00","hook":{"resource":{"addr":"terraform_data.a","module":"","resource":"terraform_data.a","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"a","resource_key":null},"action":"create","id_key":"id","id_value":"b3b64609-1f34-11e9-afe0-fcee7aa7b21d","elapsed_seconds":0},"type":"apply_complete"}
{"@level":"info","@message":"Apply complete! Resources: 1 added, 0 changed, 0 destroyed.","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.282413+01:00","changes":{"add":1,"change":0,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"apply"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 0","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.282426+01:00","outputs":{},"type":"outputs"}
"""#

    static let applyFailureStream = #"""
{"@level":"info","@message":"Terraform 1.17.1","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.316391+01:00","terraform":"1.17.1","type":"version","ui":"1.3"}
{"@level":"info","@message":"terraform_data.boom: Plan to create","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.322910+01:00","change":{"resource":{"addr":"terraform_data.boom","module":"","resource":"terraform_data.boom","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"boom","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.a: Plan to update","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.322946+01:00","change":{"resource":{"addr":"terraform_data.a","module":"","resource":"terraform_data.a","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"a","resource_key":null},"action":"update"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to add, 1 to change, 0 to destroy.","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.322955+01:00","changes":{"add":1,"change":1,"import":0,"remove":0,"action_invocation":0,"action_fail":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"terraform_data.boom: Creating...","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.324098+01:00","hook":{"resource":{"addr":"terraform_data.boom","module":"","resource":"terraform_data.boom","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"boom","resource_key":null},"action":"create"},"type":"apply_start"}
{"@level":"info","@message":"terraform_data.a: Modifying... [id=b3b64609-1f34-11e9-afe0-fcee7aa7b21d]","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.324188+01:00","hook":{"resource":{"addr":"terraform_data.a","module":"","resource":"terraform_data.a","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"a","resource_key":null},"action":"update","id_key":"id","id_value":"b3b64609-1f34-11e9-afe0-fcee7aa7b21d"},"type":"apply_start"}
{"@level":"info","@message":"terraform_data.a: Modifications complete after 0s [id=b3b64609-1f34-11e9-afe0-fcee7aa7b21d]","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.324617+01:00","hook":{"resource":{"addr":"terraform_data.a","module":"","resource":"terraform_data.a","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"a","resource_key":null},"action":"update","id_key":"id","id_value":"b3b64609-1f34-11e9-afe0-fcee7aa7b21d","elapsed_seconds":0},"type":"apply_complete"}
{"@level":"info","@message":"terraform_data.boom: Creation errored after 0s","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.326225+01:00","hook":{"resource":{"addr":"terraform_data.boom","module":"","resource":"terraform_data.boom","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"boom","resource_key":null},"action":"create","elapsed_seconds":0},"type":"apply_errored"}
{"@level":"error","@message":"Error: local-exec provisioner error","@module":"terraform.ui","@timestamp":"2026-11-02T09:21:25.326715+01:00","diagnostic":{"severity":"error","summary":"local-exec provisioner error","detail":"Error running command 'exit 1': exit status 1. Output: ","address":"terraform_data.boom","range":{"filename":"main.tf","start":{"line":6,"column":28,"byte":126},"end":{"line":6,"column":29,"byte":127}},"snippet":{"context":"resource \"terraform_data\" \"boom\"","code":"  provisioner \"local-exec\" {","start_line":6,"highlight_start_offset":27,"highlight_end_offset":28,"values":[]}},"type":"diagnostic"}
"""#

    static let tofuCreateText = #"""

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

OpenTofu will perform the following actions:

  # terraform_data.db will be created
  + resource "terraform_data" "db" {
      + id               = (known after apply)
      + triggers_replace = [
          + "v1",
        ]
    }

  # terraform_data.pw will be created
  + resource "terraform_data" "pw" {
      + id     = (known after apply)
      + input  = {
          + password = (sensitive value)
          + user     = "admin"
        }
      + output = (known after apply)
    }

  # terraform_data.web will be created
  + resource "terraform_data" "web" {
      + id     = (known after apply)
      + input  = "hello"
      + output = (known after apply)
    }

Plan: 3 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + greeting = (known after apply)
  + x        = "one"

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuCreateJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":null,"output":null,"triggers_replace":["v1"]},"after_unknown":{"id":true,"triggers_replace":[false]},"before_sensitive":false,"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":{"password":"hunter2","user":"admin"},"triggers_replace":null},"after_unknown":{"id":true,"input":{},"output":true},"before_sensitive":false,"after_sensitive":{"input":{"password":true},"output":{}}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":"hello","triggers_replace":null},"after_unknown":{"id":true,"output":true},"before_sensitive":false,"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["create"],"before":null,"after_unknown":true,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["create"],"before":null,"after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuCreateStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.399081+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.web: Plan to create","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.407992+01:00","change":{"resource":{"addr":"terraform_data.web","module":"","resource":"terraform_data.web","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"web","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.db: Plan to create","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.408145+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.pw: Plan to create","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.408163+01:00","change":{"resource":{"addr":"terraform_data.pw","module":"","resource":"terraform_data.pw","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"pw","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 3 to add, 0 to change, 0 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.408176+01:00","changes":{"add":3,"change":0,"import":0,"remove":0,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.408216+01:00","outputs":{"greeting":{"sensitive":false,"action":"create"},"x":{"sensitive":false,"action":"create"}},"type":"outputs"}
"""#

    static let tofuNoopText = #"""
terraform_data.db: Refreshing state... [id=c9a2428f-ef8a-ea85-08ba-ac741d91f70f]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.pw: Refreshing state... [id=7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed]

No changes. Your infrastructure matches the configuration.
"""#

    static let tofuNoopJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c9a2428f-ef8a-ea85-08ba-ac741d91f70f","input":null,"output":null,"triggers_replace":["v1"]},"after":{"id":"c9a2428f-ef8a-ea85-08ba-ac741d91f70f","input":null,"output":null,"triggers_replace":["v1"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"triggers_replace":null},"after":{"id":"7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"triggers_replace":null},"after_unknown":{},"before_sensitive":{"input":{"password":true},"output":{}},"after_sensitive":{"input":{"password":true},"output":{}}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello","output":"hello","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello","output":"hello","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello","after":"hello","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuNoopStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.674762+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.685174+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.685254+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let tofuOutputsOnlyText = #"""
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.db: Refreshing state... [id=c9a2428f-ef8a-ea85-08ba-ac741d91f70f]
terraform_data.pw: Refreshing state... [id=7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed]

Changes to Outputs:
  ~ x        = "one" -> "two"

You can apply this plan to save these new output values to the OpenTofu
state, without changing any real infrastructure.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuOutputsOnlyJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c9a2428f-ef8a-ea85-08ba-ac741d91f70f","input":null,"output":null,"triggers_replace":["v1"]},"after":{"id":"c9a2428f-ef8a-ea85-08ba-ac741d91f70f","input":null,"output":null,"triggers_replace":["v1"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"triggers_replace":null},"after":{"id":"7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"triggers_replace":null},"after_unknown":{},"before_sensitive":{"input":{"password":true},"output":{}},"after_sensitive":{"input":{"password":true},"output":{}}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello","output":"hello","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello","output":"hello","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello","after":"hello","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["update"],"before":"one","after":"two","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuOutputsOnlyStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.891908+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.901566+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:22.901634+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"update"}},"type":"outputs"}
"""#

    static let tofuMixedText = #"""
terraform_data.pw: Refreshing state... [id=7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.db: Refreshing state... [id=c9a2428f-ef8a-ea85-08ba-ac741d91f70f]

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create
  ~ update in-place (current -> planned)
  - destroy
-/+ destroy and then create replacement

OpenTofu will perform the following actions:

  # terraform_data.cache will be created
  + resource "terraform_data" "cache" {
      + id     = (known after apply)
      + input  = "fresh"
      + output = (known after apply)
    }

  # terraform_data.db must be replaced
-/+ resource "terraform_data" "db" {
      ~ id               = "c9a2428f-ef8a-ea85-08ba-ac741d91f70f" -> (known after apply)
      ~ triggers_replace = [
          - "v1",
          + "v2",
        ]
    }

  # terraform_data.pw will be destroyed
  # (because terraform_data.pw is not in configuration)
  - resource "terraform_data" "pw" {
      - id     = "7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed" -> null
      - input  = {
          - password = (sensitive value)
          - user     = "admin"
        } -> null
      - output = {
          - password = "hunter2"
          - user     = "admin"
        } -> null
    }

  # terraform_data.web will be updated in-place
  ~ resource "terraform_data" "web" {
        id     = "d31276dc-fad7-f63f-4016-a56a1f95d045"
      ~ input  = "hello" -> "hello again"
      ~ output = "hello" -> (known after apply)
    }

Plan: 2 to add, 1 to change, 2 to destroy.

Changes to Outputs:
  ~ greeting = "hello" -> (known after apply)

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuMixedJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"cache","provider_name":"terraform.io/builtin/terraform","change":{"actions":["create"],"before":null,"after":{"input":"fresh","triggers_replace":null},"after_unknown":{"id":true,"output":true},"before_sensitive":false,"after_sensitive":{}}},{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete","create"],"before":{"id":"c9a2428f-ef8a-ea85-08ba-ac741d91f70f","input":null,"output":null,"triggers_replace":["v1"]},"after":{"input":null,"output":null,"triggers_replace":["v2"]},"after_unknown":{"id":true,"triggers_replace":[false]},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]},"replace_paths":[["triggers_replace"]]},"action_reason":"replace_because_cannot_update"},{"address":"terraform_data.pw","mode":"managed","type":"terraform_data","name":"pw","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete"],"before":{"id":"7f39b6d9-0e03-5c68-1859-cf9ff5a9b5ed","input":{"password":"hunter2","user":"admin"},"output":{"password":"hunter2","user":"admin"},"triggers_replace":null},"after":null,"after_unknown":{},"before_sensitive":{"input":{"password":true},"output":{}},"after_sensitive":false},"action_reason":"delete_because_no_resource_config"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["update"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello","output":"hello","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","triggers_replace":null},"after_unknown":{"output":true},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["update"],"before":"hello","after_unknown":true,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuMixedStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.115172+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.cache: Plan to create","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.125925+01:00","change":{"resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"create"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.web: Plan to update","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.125999+01:00","change":{"resource":{"addr":"terraform_data.web","module":"","resource":"terraform_data.web","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"web","resource_key":null},"action":"update"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.pw: Plan to delete","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.126014+01:00","change":{"resource":{"addr":"terraform_data.pw","module":"","resource":"terraform_data.pw","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"pw","resource_key":null},"action":"delete","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.db: Plan to replace","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.126033+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"replace","reason":"cannot_update"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 2 to add, 1 to change, 2 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.126047+01:00","changes":{"add":2,"change":1,"import":0,"remove":2,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.126078+01:00","outputs":{"greeting":{"sensitive":false,"action":"update"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let tofuTaintedText = #"""
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.cache: Refreshing state... [id=5c3697f2-6c2a-918f-8f6a-ee76c0db43e2]
terraform_data.db: Refreshing state... [id=c5a11cb8-9d8a-afb0-7559-ca2e6669af47]

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
-/+ destroy and then create replacement

OpenTofu will perform the following actions:

  # terraform_data.db is tainted, so it must be replaced
-/+ resource "terraform_data" "db" {
      ~ id               = "c5a11cb8-9d8a-afb0-7559-ca2e6669af47" -> (known after apply)
        # (1 unchanged attribute hidden)
    }

Plan: 1 to add, 0 to change, 1 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuTaintedJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"cache","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}},{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete","create"],"before":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after":{"input":null,"output":null,"triggers_replace":["v2"]},"after_unknown":{"id":true,"triggers_replace":[false]},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}},"action_reason":"replace_because_tainted"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuTaintedStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.426638+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.db: Plan to replace","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.437537+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"replace","reason":"tainted"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to add, 0 to change, 1 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.437634+01:00","changes":{"add":1,"change":0,"import":0,"remove":1,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.437660+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let tofuReplaceRequestedText = #"""
terraform_data.cache: Refreshing state... [id=5c3697f2-6c2a-918f-8f6a-ee76c0db43e2]
terraform_data.db: Refreshing state... [id=c5a11cb8-9d8a-afb0-7559-ca2e6669af47]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
-/+ destroy and then create replacement

OpenTofu will perform the following actions:

  # terraform_data.cache will be replaced, as requested
-/+ resource "terraform_data" "cache" {
      ~ id     = "5c3697f2-6c2a-918f-8f6a-ee76c0db43e2" -> (known after apply)
      ~ output = "fresh" -> (known after apply)
        # (1 unchanged attribute hidden)
    }

Plan: 1 to add, 0 to change, 1 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuReplaceRequestedJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"cache","provider_name":"terraform.io/builtin/terraform","change":{"actions":["delete","create"],"before":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after":{"input":"fresh","triggers_replace":null},"after_unknown":{"id":true,"output":true},"before_sensitive":{},"after_sensitive":{}},"action_reason":"replace_by_request"},{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuReplaceRequestedStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.685196+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.cache: Plan to replace","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.694118+01:00","change":{"resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"replace","reason":"requested"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to add, 0 to change, 1 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.694191+01:00","changes":{"add":1,"change":0,"import":0,"remove":1,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.694215+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let tofuMovedText = #"""
terraform_data.db: Refreshing state... [id=c5a11cb8-9d8a-afb0-7559-ca2e6669af47]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.store: Refreshing state... [id=5c3697f2-6c2a-918f-8f6a-ee76c0db43e2]

OpenTofu will perform the following actions:

  # terraform_data.cache has moved to terraform_data.store
    resource "terraform_data" "store" {
        id     = "5c3697f2-6c2a-918f-8f6a-ee76c0db43e2"
        # (2 unchanged attributes hidden)
    }

Plan: 0 to add, 0 to change, 0 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuMovedJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.store","previous_address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuMovedStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.907800+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.store: Plan to move","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.914764+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"previous_resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"move"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.914852+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:23.914884+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let tofuMovedAndUpdatedText = #"""
terraform_data.db: Refreshing state... [id=c5a11cb8-9d8a-afb0-7559-ca2e6669af47]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.store: Refreshing state... [id=5c3697f2-6c2a-918f-8f6a-ee76c0db43e2]

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  ~ update in-place (current -> planned)

OpenTofu will perform the following actions:

  # terraform_data.store will be updated in-place
  # (moved from terraform_data.cache)
  ~ resource "terraform_data" "store" {
        id     = "5c3697f2-6c2a-918f-8f6a-ee76c0db43e2"
      ~ input  = "fresh" -> "fresher"
      ~ output = "fresh" -> (known after apply)
    }

Plan: 0 to add, 1 to change, 0 to destroy.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuMovedAndUpdatedJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.store","previous_address":"terraform_data.cache","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["update"],"before":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresher","triggers_replace":null},"after_unknown":{"output":true},"before_sensitive":{},"after_sensitive":{}}},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuMovedAndUpdatedStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.123820+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.store: Plan to update","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.134160+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"previous_resource":{"addr":"terraform_data.cache","module":"","resource":"terraform_data.cache","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"cache","resource_key":null},"action":"update"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 1 to change, 0 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.134248+01:00","changes":{"add":0,"change":1,"import":0,"remove":0,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.134272+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
"""#

    static let tofuForgetText = #"""
terraform_data.store: Refreshing state... [id=5c3697f2-6c2a-918f-8f6a-ee76c0db43e2]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.db: Refreshing state... [id=c5a11cb8-9d8a-afb0-7559-ca2e6669af47]

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  . forget

OpenTofu will perform the following actions:

  # terraform_data.store will be removed from the OpenTofu state but will not be destroyed
  . resource "terraform_data" "store" {
    id     = "5c3697f2-6c2a-918f-8f6a-ee76c0db43e2"
    input  = "fresh"
    output = "fresh"
}

Plan: 0 to add, 0 to change, 0 to destroy, 1 to forget.

Warning: Resource will be removed from the state

After this plan is applied, the resource terraform_data.store will not be
managed anymore by OpenTofu.

In case you want to manage the resource again, you will have to import it.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuForgetJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.store","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["forget"],"before":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after":null,"after_unknown":{},"before_sensitive":{},"after_sensitive":false},"action_reason":"delete_because_no_resource_config"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuForgetStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.390426+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.store: Plan to remove","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.399321+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"action":"remove","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 0 to destroy, 1 to forget.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.399430+01:00","changes":{"add":0,"change":0,"import":0,"remove":0,"forget":1,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.399464+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
{"@level":"warn","@message":"Warning: Resource will be removed from the state","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.399501+01:00","diagnostic":{"severity":"warning","summary":"Resource will be removed from the state","detail":"After this plan is applied, the resource terraform_data.store will not be managed anymore by OpenTofu.\n\nIn case you want to manage the resource again, you will have to import it."},"type":"diagnostic"}
"""#

    static let tofuImportedText = #"""
terraform_data.store: Refreshing state... [id=5c3697f2-6c2a-918f-8f6a-ee76c0db43e2]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]
terraform_data.imp: Preparing import... [id=imported-1]
terraform_data.imp: Refreshing state... [id=imported-1]
terraform_data.db: Refreshing state... [id=c5a11cb8-9d8a-afb0-7559-ca2e6669af47]

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  ~ update in-place (current -> planned)
  . forget

OpenTofu will perform the following actions:

  # terraform_data.imp will be updated in-place
  # (imported from "imported-1")
  ~ resource "terraform_data" "imp" {
        id     = "imported-1"
      + input  = "imported-1"
      + output = (known after apply)
    }

  # terraform_data.store will be removed from the OpenTofu state but will not be destroyed
  . resource "terraform_data" "store" {
    id     = "5c3697f2-6c2a-918f-8f6a-ee76c0db43e2"
    input  = "fresh"
    output = "fresh"
}

Plan: 1 to import, 0 to add, 1 to change, 0 to destroy, 1 to forget.

Warning: Resource will be removed from the state

After this plan is applied, the resource terraform_data.store will not be
managed anymore by OpenTofu.

In case you want to manage the resource again, you will have to import it.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so OpenTofu can't
guarantee to take exactly these actions if you run "tofu apply" now.
"""#

    static let tofuImportedJSON = #"""
{"format_version":"1.2","terraform_version":"1.13.2","errored":false,"resource_changes":[{"address":"terraform_data.db","mode":"managed","type":"terraform_data","name":"db","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after":{"id":"c5a11cb8-9d8a-afb0-7559-ca2e6669af47","input":null,"output":null,"triggers_replace":["v2"]},"after_unknown":{},"before_sensitive":{"triggers_replace":[false]},"after_sensitive":{"triggers_replace":[false]}}},{"address":"terraform_data.imp","mode":"managed","type":"terraform_data","name":"imp","provider_name":"terraform.io/builtin/terraform","change":{"actions":["update"],"before":{"id":"imported-1","input":null,"output":null,"triggers_replace":null},"after":{"id":"imported-1","input":"imported-1","triggers_replace":null},"after_unknown":{"output":true},"before_sensitive":{},"after_sensitive":{},"importing":{"id":"imported-1"}}},{"address":"terraform_data.store","mode":"managed","type":"terraform_data","name":"store","provider_name":"terraform.io/builtin/terraform","change":{"actions":["forget"],"before":{"id":"5c3697f2-6c2a-918f-8f6a-ee76c0db43e2","input":"fresh","output":"fresh","triggers_replace":null},"after":null,"after_unknown":{},"before_sensitive":{},"after_sensitive":false},"action_reason":"delete_because_no_resource_config"},{"address":"terraform_data.web","mode":"managed","type":"terraform_data","name":"web","provider_name":"terraform.io/builtin/terraform","change":{"actions":["no-op"],"before":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after":{"id":"d31276dc-fad7-f63f-4016-a56a1f95d045","input":"hello again","output":"hello again","triggers_replace":null},"after_unknown":{},"before_sensitive":{},"after_sensitive":{}}}],"output_changes":{"greeting":{"actions":["no-op"],"before":"hello again","after":"hello again","after_unknown":false,"before_sensitive":false,"after_sensitive":false},"x":{"actions":["no-op"],"before":"one","after":"one","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"planned_values":{}}
"""#

    static let tofuImportedStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.602780+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.store: Plan to remove","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.612976+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"action":"remove","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.imp: Plan to update","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.613089+01:00","change":{"resource":{"addr":"terraform_data.imp","module":"","resource":"terraform_data.imp","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"imp","resource_key":null},"action":"update","importing":{"id":"imported-1"}},"type":"planned_change"}
{"@level":"info","@message":"Plan: 1 to import, 0 to add, 1 to change, 0 to destroy, 1 to forget.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.613115+01:00","changes":{"add":0,"change":1,"import":1,"remove":0,"forget":1,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.613145+01:00","outputs":{"greeting":{"sensitive":false,"action":"noop"},"x":{"sensitive":false,"action":"noop"}},"type":"outputs"}
{"@level":"warn","@message":"Warning: Resource will be removed from the state","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.613178+01:00","diagnostic":{"severity":"warning","summary":"Resource will be removed from the state","detail":"After this plan is applied, the resource terraform_data.store will not be managed anymore by OpenTofu.\n\nIn case you want to manage the resource again, you will have to import it."},"type":"diagnostic"}
"""#

    static let tofuErroredText = #"""
terraform_data.db: Refreshing state... [id=c5a11cb8-9d8a-afb0-7559-ca2e6669af47]
terraform_data.store: Refreshing state... [id=5c3697f2-6c2a-918f-8f6a-ee76c0db43e2]
terraform_data.web: Refreshing state... [id=d31276dc-fad7-f63f-4016-a56a1f95d045]

OpenTofu used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  - destroy

OpenTofu planned the following actions, but then encountered a problem:

  # terraform_data.db will be destroyed
  # (because terraform_data.db is not in configuration)
  - resource "terraform_data" "db" {
      - id               = "c5a11cb8-9d8a-afb0-7559-ca2e6669af47" -> null
      - triggers_replace = [
          - "v2",
        ] -> null
    }

  # terraform_data.store will be destroyed
  # (because terraform_data.store is not in configuration)
  - resource "terraform_data" "store" {
      - id     = "5c3697f2-6c2a-918f-8f6a-ee76c0db43e2" -> null
      - input  = "fresh" -> null
      - output = "fresh" -> null
    }

Plan: 0 to add, 0 to change, 2 to destroy.

Changes to Outputs:
  - greeting = "hello again" -> null
  - x        = "one" -> null

Error: Resource precondition failed

  on main.tf line 11, in resource "terraform_data" "late":
  11:       condition     = var.x == "never"
    ├────────────────
    │ var.x is "one"
    ├────────────────
    │ Diff: 
    │     "one" -> "never"

x must be never
"""#

    static let tofuErroredStream = #"""
{"@level":"info","@message":"OpenTofu 1.13.2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.780491+01:00","tofu":"1.13.2","type":"version","ui":"1.2"}
{"@level":"info","@message":"terraform_data.store: Plan to delete","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.787707+01:00","change":{"resource":{"addr":"terraform_data.store","module":"","resource":"terraform_data.store","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"store","resource_key":null},"action":"delete","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"terraform_data.db: Plan to delete","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.787748+01:00","change":{"resource":{"addr":"terraform_data.db","module":"","resource":"terraform_data.db","implied_provider":"terraform","resource_type":"terraform_data","resource_name":"db","resource_key":null},"action":"delete","reason":"delete_because_no_resource_config"},"type":"planned_change"}
{"@level":"info","@message":"Plan: 0 to add, 0 to change, 2 to destroy.","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.787758+01:00","changes":{"add":0,"change":0,"import":0,"remove":2,"forget":0,"operation":"plan"},"type":"change_summary"}
{"@level":"info","@message":"Outputs: 2","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.787783+01:00","outputs":{"greeting":{"sensitive":false,"action":"delete"},"x":{"sensitive":false,"action":"delete"}},"type":"outputs"}
{"@level":"error","@message":"Error: Resource precondition failed","@module":"tofu.ui","@timestamp":"2026-11-02T10:00:24.787867+01:00","diagnostic":{"severity":"error","summary":"Resource precondition failed","detail":"x must be never","range":{"filename":"main.tf","start":{"line":11,"column":23,"byte":202},"end":{"line":11,"column":39,"byte":218}},"snippet":{"context":"resource \"terraform_data\" \"late\"","code":"      condition     = var.x == \"never\"","start_line":11,"highlight_start_offset":22,"highlight_end_offset":38,"values":[{"traversal":"var.x","statement":"is \"one\""}]},"difference":{"before":"one","after":"never","after_unknown":false,"before_sensitive":false,"after_sensitive":false}},"type":"diagnostic"}
"""#

}
