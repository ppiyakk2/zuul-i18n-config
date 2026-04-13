prepare-weblate-client
======================

Installs the `wlc` Weblate CLI client and writes the credential config file
(``~/.config/weblate``) so subsequent tasks can interact with the Weblate API
without embedding credentials in playbooks.

This role is modeled after the ``prepare-zanata-client`` role in
``openstack-zuul-jobs``.

Role Variables
--------------

.. zuul:rolevar:: weblate_client_version
   :default: 3.12.0

   Version of the ``wlc`` Python package to install.

.. zuul:rolevar:: weblate_url

   Base URL of the Weblate server (e.g. ``https://translate.openstack.org``).
   Should be provided via a Zuul Secret.

.. zuul:rolevar:: weblate_token

   Weblate API token for authentication.
   Should be provided via a Zuul Secret.

.. zuul:rolevar:: weblate_config_path
   :default: {{ ansible_user_dir }}/.config/weblate

   Path where the wlc INI config file will be written.

Usage
-----

Add to your playbook before any tasks that use ``wlc``::

    - name: Prepare Weblate client
      include_role:
        name: prepare-weblate-client
      vars:
        weblate_url: "{{ weblate_api_credentials.url }}"
        weblate_token: "{{ weblate_api_credentials.token }}"

The ``weblate_api_credentials`` secret should be defined in your Zuul config::

    - secret:
        name: weblate_api_credentials
        data:
          url: https://translate.openstack.org
          token: !encrypted/pkcs1-oaep
            - <encrypted token>
