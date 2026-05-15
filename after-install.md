# Plow Chat plugin installed

This plugin registers a Hermes gateway platform named `plow_chat`. The Plow Chat
API surface itself is documented in the [`seed-plow-chat`][seed] dependency.

To finish setup:

1. Clone the dep if you haven't already:

   `git clone https://github.com/plow-pbc/seed-plow-chat.git ~/.cache/seed-plow-chat`

2. Create and verify a Plow chat:

   `python3 ~/.cache/seed-plow-chat/ref/examples/create_chat.py --state ~/.hermes/plow_chat_state.json`

   Text the printed `VERIFY-XXXXXX` code to the printed Plow line, then check:

   `python3 ~/.cache/seed-plow-chat/ref/examples/check_chat.py ~/.hermes/plow_chat_state.json`

3. Configure Hermes env vars from the verified state file:

   `python3 ref/scripts/configure_hermes_env.py ~/.hermes/plow_chat_state.json`

4. Start or restart the gateway:

   `hermes gateway restart`

After that, messages sent to the verified Plow Chat thread should enter Hermes,
and Hermes replies should be sent back through Plow Chat.

[seed]: https://github.com/plow-pbc/seed-plow-chat
