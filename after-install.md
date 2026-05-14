# Plow Chat plugin installed

This plugin registers a Hermes gateway platform named `plow_chat`.

To finish setup:

1. Create and verify a Plow chat if you have not already:

   `python ref/scripts/create_chat.py --state ~/.hermes/plow_chat_state.json`

   Text the printed `VERIFY-XXXXXX` code to the printed Plow line, then check:

   `python ref/scripts/check_chat.py ~/.hermes/plow_chat_state.json`

2. Configure Hermes env vars from the verified state file:

   `python ref/scripts/configure_hermes_env.py ~/.hermes/plow_chat_state.json`

3. Start or restart the gateway:

   `hermes gateway restart`

After that, messages sent to the verified Plow Chat thread should enter Hermes,
and Hermes replies should be sent back through Plow Chat.
