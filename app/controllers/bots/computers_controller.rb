module Bots
  class ComputersController < ApplicationController
    def update
      bot = Current.user.bots.find(params[:bot_id])
      computer = bot.computer || bot.build_computer
      if computer.update(params.expect(computer: %i[ provider state notes_file ]))
        redirect_to bot, notice: computer.on? ? "Computer on. #{bot} can use files and a shell from the next message." :
          "Computer off. #{bot} has no files or shell from the next message."
      else
        redirect_to bot, alert: computer.errors.full_messages.to_sentence
      end
    end
  end
end
