import io
import json
import os
import tempfile
import unittest
from unittest import mock

import ogproxy


class ConfigTests(unittest.TestCase):
    def test_invalid_slots_fall_back_to_safe_defaults(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = os.path.join(temp_dir, "ogproxy-config.json")
            with open(config_path, "w", encoding="utf-8") as config_file:
                json.dump({"slots": {"broken": {}, "also-broken": "model"}}, config_file)

            with mock.patch.object(ogproxy, "CONFIG_PATH", config_path):
                slots = ogproxy.load_config()

        self.assertEqual(slots["gpt-5.6-sol"]["upstream_model"], "deepseek-v4-pro")
        self.assertNotIn("broken", slots)

    def test_valid_slots_are_trimmed_and_missing_default_is_restored(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = os.path.join(temp_dir, "ogproxy-config.json")
            with open(config_path, "w", encoding="utf-8") as config_file:
                json.dump(
                    {"slots": {" custom-slot ": {"upstream_model": " kimi-k3 "}}},
                    config_file,
                )

            with mock.patch.object(ogproxy, "CONFIG_PATH", config_path):
                slots = ogproxy.load_config()

        self.assertEqual(slots["custom-slot"], {
            "upstream_model": "kimi-k3",
            "display_name": "kimi-k3",
        })
        self.assertIn("gpt-5.6-sol", slots)

    def test_save_config_is_atomic_and_reports_success(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = os.path.join(temp_dir, "ogproxy-config.json")
            slots = {"gpt-5.6-sol": {
                "upstream_model": "deepseek-v4-pro",
                "display_name": "DeepSeek V4 Pro",
            }}
            with mock.patch.object(ogproxy, "CONFIG_PATH", config_path), mock.patch.object(
                ogproxy, "SLOTS", slots
            ):
                self.assertTrue(ogproxy.save_config())

            with open(config_path, encoding="utf-8") as config_file:
                self.assertEqual(json.load(config_file), {"slots": slots})
            self.assertEqual(os.listdir(temp_dir), ["ogproxy-config.json"])


class PrivacyTests(unittest.TestCase):
    def test_request_logging_is_disabled_by_default(self):
        with tempfile.TemporaryDirectory() as temp_dir, mock.patch.object(
            ogproxy, "CODEX_HOME", temp_dir
        ), mock.patch.object(ogproxy, "DEBUG_LOGS", False):
            ogproxy._dump_chat_req({"messages": [{"content": "private prompt"}]})
            self.assertEqual(os.listdir(temp_dir), [])

    def test_request_logging_can_be_explicitly_enabled(self):
        with tempfile.TemporaryDirectory() as temp_dir, mock.patch.object(
            ogproxy, "CODEX_HOME", temp_dir
        ), mock.patch.object(ogproxy, "DEBUG_LOGS", True):
            ogproxy._dump_chat_req({"messages": [{"content": "debug prompt"}]})
            path = os.path.join(temp_dir, "ogproxy-upstream.log")
            with open(path, encoding="utf-8") as log_file:
                self.assertIn("debug prompt", log_file.read())


class TranslationTests(unittest.TestCase):
    def test_parallel_tool_calls_and_outputs_are_preserved(self):
        request = {
            "input": [
                {"type": "function_call", "call_id": "call_1", "name": "one", "arguments": "{}"},
                {"type": "function_call", "call_id": "call_2", "name": "two", "arguments": "{}"},
                {"type": "function_call_output", "call_id": "call_1", "output": "first"},
                {"type": "function_call_output", "call_id": "call_2", "output": "second"},
            ]
        }

        messages = ogproxy.responses_input_to_messages(request)

        self.assertEqual([call["id"] for call in messages[0]["tool_calls"]], ["call_1", "call_2"])
        self.assertEqual([message["tool_call_id"] for message in messages[1:]], ["call_1", "call_2"])

    def test_image_url_uses_gateway_compatible_string_shape(self):
        content = [{"type": "input_image", "image_url": "data:image/png;base64,AAAA"}]

        converted = ogproxy.message_content_to_chat(content)

        self.assertEqual(converted, [{
            "type": "image_url",
            "image_url": "data:image/png;base64,AAAA",
        }])

    def test_switch_body_validation_rejects_malformed_values(self):
        valid, error = ogproxy._validate_switch_body({"upstream_model": " kimi-k3 "})
        self.assertIsNone(error)
        self.assertEqual(valid["upstream_model"], "kimi-k3")
        self.assertEqual(valid["display_name"], "kimi-k3")

        invalid, error = ogproxy._validate_switch_body({"upstream_model": "bad\nmodel"})
        self.assertIsNone(invalid)
        self.assertEqual(error, "invalid upstream_model")


class StreamTests(unittest.TestCase):
    def test_stream_translator_emits_completed_response(self):
        output = io.BytesIO()
        translator = ogproxy.StreamTranslator(output)
        translator.start("gpt-5.6-sol", None)
        translator.feed_chunk({"choices": [{"delta": {"content": "OK"}, "finish_reason": "stop"}]})

        events = output.getvalue().decode("utf-8")
        self.assertIn("event: response.output_text.delta", events)
        self.assertIn('"status": "completed"', events)


if __name__ == "__main__":
    unittest.main()
