from django.core.cache import cache
from rest_framework.authentication import TokenAuthentication
from rest_framework import exceptions

class CachedTokenAuthentication(TokenAuthentication):
    """
    Cached token authentication class.
    Caches token lookup and user session queries to support high concurrency (1000+ users)
    without hitting database limits.
    """
    def authenticate_credentials(self, key):
        cache_key = f"auth_token_credentials_{key}"
        cached_result = cache.get(cache_key)
        
        if cached_result is not None:
            user_id, token_pk = cached_result
            
            # Fetch user from cache, falling back to database
            user_cache_key = f"auth_user_{user_id}"
            user = cache.get(user_cache_key)
            if not user:
                from api.models import User
                user = User.objects.select_related('permission', 'tsp_provider').filter(pk=user_id).first()
                if user:
                    cache.set(user_cache_key, user, timeout=3600)  # Cache for 1 hour
            
            # Fetch token from cache, falling back to database
            token_cache_key = f"auth_token_obj_{token_pk}"
            token = cache.get(token_cache_key)
            if not token:
                from rest_framework.authtoken.models import Token
                token = Token.objects.filter(pk=token_pk).first()
                if token:
                    cache.set(token_cache_key, token, timeout=3600)  # Cache for 1 hour
            
            if user and token:
                if not user.is_active:
                    raise exceptions.AuthenticationFailed('User inactive or deleted.')
                return (user, token)
                
        # Cache miss: perform regular token lookup
        user, token = super().authenticate_credentials(key)
        
        # Optimize the retrieved user object relationships if not loaded
        if not hasattr(user, 'permission') or not hasattr(user, 'tsp_provider'):
            from api.models import User as ApiUser
            try:
                user = ApiUser.objects.select_related('permission', 'tsp_provider').get(pk=user.id)
            except ApiUser.DoesNotExist:
                pass
        
        # Save to cache
        cache.set(cache_key, (user.id, token.pk), timeout=300)  # Cache credential validation for 5 minutes
        cache.set(f"auth_user_{user.id}", user, timeout=3600)
        cache.set(f"auth_token_obj_{token.pk}", token, timeout=3600)
        
        return (user, token)
