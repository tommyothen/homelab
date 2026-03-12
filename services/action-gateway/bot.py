"""Discord bot for the Action Gateway.

Runs as a persistent WebSocket connection to Discord. When the FastAPI app
queues a new action, it calls ``bot.post_action_request()``, which posts an
embed with Approve/Deny buttons to the configured mission-control channel.

Button interactions are handled entirely over the existing WebSocket — no
public HTTP endpoint is needed.
"""

import asyncio
import logging
from datetime import datetime, timedelta
from typing import Optional

import discord
from discord.ui import Button, View

from db import update_action
from executor import run_script

logger = logging.getLogger(__name__)

# Discord embed field values are capped at 1024 chars; code blocks need room.
_MAX_OUTPUT = 900


class ActionView(View):
    """A discord.ui.View with Approve and Deny buttons for a single action."""

    def __init__(
        self,
        *,
        action_id: str,
        action_name: str,
        action_config: dict,
        approver_role_id: int,
        scripts_dir: str,
        db_path: str,
        expiry_minutes: int = 15,
        env_overrides: Optional[dict[str, str]] = None,
    ) -> None:
        super().__init__(timeout=expiry_minutes * 60)
        self.action_id = action_id
        self.action_name = action_name
        self.action_config = action_config
        self.approver_role_id = approver_role_id
        self.scripts_dir = scripts_dir
        self.db_path = db_path
        self.env_overrides = env_overrides
        self._resolved = False
        # Set after the message is sent so on_timeout can edit it.
        self.message: Optional[discord.Message] = None

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _has_permission(self, interaction: discord.Interaction) -> bool:
        if not isinstance(interaction.user, discord.Member):
            return False
        return any(r.id == self.approver_role_id for r in interaction.user.roles)

    def _disable_all(self) -> None:
        for item in self.children:
            item.disabled = True  # type: ignore[union-attr]

    # ------------------------------------------------------------------
    # Timeout
    # ------------------------------------------------------------------

    async def on_timeout(self) -> None:
        await update_action(self.db_path, self.action_id, "expired")
        if self.message is None:
            logger.info("No message to update for expired action %s", self.action_id)
            return
        self._disable_all()
        try:
            embed = self.message.embeds[0].copy()
            embed.color = discord.Color.dark_gray()
            embed.add_field(name="Status", value="⏰ Expired — no response within the window", inline=False)
            await self.message.edit(embed=embed, view=self)
        except discord.NotFound:
            logger.warning("Message deleted before timeout update (action %s)", self.action_id)
        except discord.Forbidden:
            logger.error("No permission to edit message (action %s)", self.action_id)
        except discord.HTTPException:
            logger.exception("Failed to update expired action message %s", self.action_id)

    # ------------------------------------------------------------------
    # Buttons
    # ------------------------------------------------------------------

    @discord.ui.button(label="Approve", style=discord.ButtonStyle.green, emoji="✅")
    async def approve(self, interaction: discord.Interaction, button: Button) -> None:
        if self._resolved:
            await interaction.response.send_message(
                "This action has already been resolved.", ephemeral=True
            )
            return

        if not self._has_permission(interaction):
            await interaction.response.send_message(
                "You don't have the required role to approve actions.", ephemeral=True
            )
            return

        self._resolved = True
        self.stop()
        self._disable_all()

        # Acknowledge the interaction immediately; execution may take a while.
        await interaction.response.defer()

        embed = interaction.message.embeds[0].copy()
        embed.color = discord.Color.green()
        embed.add_field(
            name="Status",
            value=f"✅ Approved by **{interaction.user.display_name}**",
            inline=False,
        )
        await interaction.message.edit(embed=embed, view=self)

        # Run the script.
        result = await run_script(
            self.scripts_dir,
            self.action_config["script"],
            self.action_config.get("timeout", 60),
            env_overrides=self.env_overrides,
        )

        final_status = "completed" if result["success"] else "failed"
        stored_result = (
            f"returncode={result['returncode']}\n"
            f"stdout={result['stdout']}\n"
            f"stderr={result['stderr']}"
        )
        await update_action(
            self.db_path,
            self.action_id,
            final_status,
            actioned_by=str(interaction.user),
            result=stored_result,
        )

        # Build result embed.
        icon = "✅" if result["success"] else "❌"
        result_embed = discord.Embed(
            title=f"{icon} Result: `{self.action_name}`",
            color=discord.Color.green() if result["success"] else discord.Color.red(),
            timestamp=datetime.utcnow(),
        )
        result_embed.add_field(name="Exit code", value=str(result["returncode"]), inline=True)
        if result["stdout"]:
            result_embed.add_field(
                name="stdout",
                value=f"```\n{result['stdout'][:_MAX_OUTPUT]}\n```",
                inline=False,
            )
        if result["stderr"]:
            result_embed.add_field(
                name="stderr",
                value=f"```\n{result['stderr'][:_MAX_OUTPUT]}\n```",
                inline=False,
            )
        result_embed.set_footer(text=f"Action ID: {self.action_id}")
        await interaction.followup.send(embed=result_embed)

    @discord.ui.button(label="Deny", style=discord.ButtonStyle.red, emoji="❌")
    async def deny(self, interaction: discord.Interaction, button: Button) -> None:
        if self._resolved:
            await interaction.response.send_message(
                "This action has already been resolved.", ephemeral=True
            )
            return

        if not self._has_permission(interaction):
            await interaction.response.send_message(
                "You don't have the required role to deny actions.", ephemeral=True
            )
            return

        self._resolved = True
        self.stop()
        self._disable_all()

        embed = interaction.message.embeds[0].copy()
        embed.color = discord.Color.red()
        embed.add_field(
            name="Status",
            value=f"❌ Denied by **{interaction.user.display_name}**",
            inline=False,
        )
        await interaction.message.edit(embed=embed, view=self)

        await update_action(
            self.db_path,
            self.action_id,
            "denied",
            actioned_by=str(interaction.user),
        )

        await interaction.response.send_message(
            f"Action `{self.action_name}` denied.", ephemeral=True
        )


class ActionGatewayBot(discord.Client):
    """discord.py client that manages approval interactions for the gateway."""

    def __init__(
        self,
        *,
        channel_id: int,
        approver_role_id: int,
        scripts_dir: str,
        db_path: str,
        expiry_minutes: int = 15,
    ) -> None:
        intents = discord.Intents.default()
        super().__init__(intents=intents)
        self.channel_id = channel_id
        self.approver_role_id = approver_role_id
        self.scripts_dir = scripts_dir
        self.db_path = db_path
        self.expiry_minutes = expiry_minutes
        # Signalled once on_ready fires so callers can await bot readiness.
        self._ready_event: asyncio.Event = asyncio.Event()

    async def on_ready(self) -> None:
        logger.info("Discord bot ready: %s (id=%s)", self.user, self.user.id)  # type: ignore[union-attr]
        self._ready_event.set()

    async def post_action_request(
        self,
        action_id: str,
        action_name: str,
        action_config: dict,
        requested_by: str,
        reason: Optional[str] = None,
        context: Optional[dict[str, str]] = None,
        env_overrides: Optional[dict[str, str]] = None,
    ) -> None:
        """Post a Discord message with Approve/Deny buttons for the given action."""
        # Wait until the bot has connected and received its READY payload.
        await self._ready_event.wait()

        channel = self.get_channel(self.channel_id)
        if channel is None:
            logger.error("Mission-control channel %d not found — is the bot in the server?", self.channel_id)
            return

        expiry_dt = datetime.utcnow() + timedelta(minutes=self.expiry_minutes)
        expiry_unix = int(expiry_dt.timestamp())

        embed = discord.Embed(
            title=f"Action Request: `{action_name}`",
            description=action_config.get("description", "*(no description)*"),
            color=discord.Color.yellow(),
            timestamp=datetime.utcnow(),
        )
        embed.add_field(name="Requested by", value=requested_by, inline=True)
        embed.add_field(name="Script", value=f"`{action_config['script']}`", inline=True)
        embed.add_field(name="Timeout", value=f"{action_config.get('timeout', 60)}s", inline=True)
        embed.add_field(name="Expires", value=f"<t:{expiry_unix}:R>", inline=True)
        if reason:
            embed.add_field(name="Reason", value=reason, inline=False)
        if context:
            ctx_str = "\n".join(f"**{k}:** `{v}`" for k, v in context.items())
            embed.add_field(name="Parameters", value=ctx_str, inline=False)
        embed.set_footer(text=f"Action ID: {action_id}")

        view = ActionView(
            action_id=action_id,
            action_name=action_name,
            action_config=action_config,
            approver_role_id=self.approver_role_id,
            scripts_dir=self.scripts_dir,
            db_path=self.db_path,
            expiry_minutes=self.expiry_minutes,
            env_overrides=env_overrides,
        )

        message = await channel.send(embed=embed, view=view)  # type: ignore[union-attr]
        view.message = message
        logger.info("Posted action request %s to channel %d", action_id, self.channel_id)
