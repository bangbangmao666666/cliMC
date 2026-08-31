import unittest


from app.intents import CommandKind, parse_intent


class IntentTests(unittest.TestCase):
    def test_recognizes_the_six_supported_spoken_commands(self):
        self.assertIs(parse_intent("新开一个任务").kind, CommandKind.NEW_TASK)
        self.assertIs(parse_intent("压缩一下上下文").kind, CommandKind.COMPACT)
        self.assertEqual(parse_intent("目标是修复登录问题").objective, "修复登录问题")
        self.assertIs(parse_intent("暂停目标").kind, CommandKind.PAUSE_GOAL)
        self.assertIs(parse_intent("继续目标").kind, CommandKind.RESUME_GOAL)
        self.assertIs(parse_intent("清除目标").kind, CommandKind.CLEAR_GOAL)

    def test_non_command_remains_a_normal_prompt(self):
        intent = parse_intent("帮我看看这个报错怎么修")

        self.assertIs(intent.kind, CommandKind.PROMPT)
        self.assertEqual(intent.text, "帮我看看这个报错怎么修")
