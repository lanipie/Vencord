/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import definePlugin from "@utils/types";

export default definePlugin({
    name: "customGreeting",
    description: "Pastes a custom greeting into the textfield",
    authors: [{ name: "Lani Pie", id: 217057058141241344n }],

    commands: [
        {
            name: "greet",
            description: "Greets with current time (local for everyone)",
            execute: (args, ctx) => {
                const now = Math.floor(Date.now() / 1000);
                const message = `Good <t:${now}:t> everyone`;

                // Returning with type: 4 inserts this text into the text field
                return {
                    type: 4,
                    content: message
                };
            }

        }
    ]
});
