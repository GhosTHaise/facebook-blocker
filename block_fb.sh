#!/bin/bash

# Le domaine à bloquer
DOMAIN="www.facebook.com"
IP_BLOCK="127.0.0.1"

if [ "$1" == "block" ]; then
    # Supprime la ligne si elle existe déjà, puis l'ajoute pour bloquer
    sed -i "/$DOMAIN/d" /etc/hosts
    echo "$IP_BLOCK $DOMAIN" >> /etc/hosts
    echo "Facebook est maintenant bloqué."

elif [ "$1" == "unblock" ]; then
    # Supprime la ligne de blocage
    sed -i "/$DOMAIN/d" /etc/hosts
    echo "Facebook est débloqué pour 3 minutes !"
fi