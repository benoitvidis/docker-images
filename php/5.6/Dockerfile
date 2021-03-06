FROM debian:jessie
MAINTAINER Kaliop
LABEL php.version=5.6

# Base packages
# Java (used for eg. eZTika indexing)
# poppler-utils used for pdftotext binary (note that eztika is a much better option!)
# -----------------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y \
    apt-transport-https \
    ca-certificates \
    wget \
    curl \
    netcat \
    jpegoptim \
    imagemagick \
    sudo \
    vim \
    nano \
    poppler-utils \
    openjdk-7-jre-headless \
    pwgen \
    locales \
    unzip

# PHP packages
# -----------------------------------------------------------------------------
RUN apt-get install -y \
    php5 \
    php5-readline \
    php5-mysqlnd \
    php5-json \
    php5-xsl \
    php5-intl \
    php5-mcrypt \
    php5-curl \
    php5-imagick \
    php5-gd \
    php5-xmlrpc \
    php5-memcached \
    php5-xdebug

# PHP config
# -----------------------------------------------------------------------------
# Custom PHP variables
RUN curl -L -o /etc/php5/cli/conf.d/custom_vars.ini https://raw.githubusercontent.com/kaliop/docker-images/master/build_files/php/custom_vars.ini && \
    cp /etc/php5/cli/conf.d/custom_vars.ini /etc/php5/apache2/conf.d/custom_vars.ini

# remove default xdebug config
RUN rm /etc/php5/cli/conf.d/20-xdebug.ini && \
    rm /etc/php5/apache2/conf.d/20-xdebug.ini

# Clear archives in apt cache folder
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/bin/bash"]